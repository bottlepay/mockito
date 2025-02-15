// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:vm_service/vm_service.dart';

import 'util.dart';
import 'hitmap.dart';

const _retryInterval = Duration(milliseconds: 200);

/// Collects coverage for all isolates in the running VM.
///
/// Collects a hit-map containing merged coverage for all isolates in the Dart
/// VM associated with the specified [serviceUri]. Returns a map suitable for
/// input to the coverage formatters that ship with this package.
///
/// [serviceUri] must specify the http/https URI of the service port of a
/// running Dart VM and must not be null.
///
/// If [resume] is true, all isolates will be resumed once coverage collection
/// is complete.
///
/// If [waitPaused] is true, collection will not begin until all isolates are
/// in the paused state.
///
/// If [includeDart] is true, code coverage for core `dart:*` libraries will be
/// collected.
///
/// If [functionCoverage] is true, function coverage information will be
/// collected.
///
/// If [scopedOutput] is non-empty, coverage will be restricted so that only
/// scripts that start with any of the provided paths are considered.
///
/// if [isolateIds] is set, the coverage gathering will be restricted to only
/// those VM isolates.
Future<Map<String, dynamic>> collect(Uri serviceUri, bool resume,
    bool waitPaused, bool includeDart, Set<String>? scopedOutput,
    {Set<String>? isolateIds,
    Duration? timeout,
    bool functionCoverage = false}) async {
  scopedOutput ??= <String>{};

  // Create websocket URI. Handle any trailing slashes.
  final pathSegments =
      serviceUri.pathSegments.where((c) => c.isNotEmpty).toList()..add('ws');
  final uri = serviceUri.replace(scheme: 'ws', pathSegments: pathSegments);

  late VmService service;
  await retry(() async {
    try {
      final options = const CompressionOptions(enabled: false);
      final socket = await WebSocket.connect('$uri', compression: options);
      final controller = StreamController<String>();
      socket.listen((data) => controller.add(data as String), onDone: () {
        controller.close();
        service.dispose();
      });
      service = VmService(
          controller.stream, (String message) => socket.add(message),
          log: StdoutLog(), disposeHandler: () => socket.close());
      await service.getVM().timeout(_retryInterval);
    } on TimeoutException {
      // The signature changed in vm_service version 6.0.0.
      // ignore: await_only_futures
      await service.dispose();
      rethrow;
    }
  }, _retryInterval, timeout: timeout);
  try {
    if (waitPaused) {
      await _waitIsolatesPaused(service, timeout: timeout);
    }

    return await _getAllCoverage(
        service, includeDart, functionCoverage, scopedOutput, isolateIds);
  } finally {
    if (resume) {
      await _resumeIsolates(service);
    }
    // The signature changed in vm_service version 6.0.0.
    // ignore: await_only_futures
    await service.dispose();
  }
}

Future<Map<String, dynamic>> _getAllCoverage(
    VmService service,
    bool includeDart,
    bool functionCoverage,
    Set<String>? scopedOutput,
    Set<String>? isolateIds) async {
  scopedOutput ??= <String>{};
  final vm = await service.getVM();
  final allCoverage = <Map<String, dynamic>>[];
  final version = await service.getVersion();
  final reportLines =
      (version.major == 3 && version.minor != null && version.minor! >= 51) ||
          (version.major != null && version.major! > 3);

  // Program counters are shared between isolates in the same group. So we need
  // to make sure we're only gathering coverage data for one isolate in each
  // group, otherwise we'll double count the hits.
  final isolateOwnerGroup = <String, String>{};
  final coveredIsolateGroups = <String>{};
  for (var isolateGroupRef in vm.isolateGroups!) {
    final isolateGroup = await service.getIsolateGroup(isolateGroupRef.id!);
    for (var isolateRef in isolateGroup.isolates!) {
      isolateOwnerGroup[isolateRef.id!] = isolateGroupRef.id!;
    }
  }

  for (var isolateRef in vm.isolates!) {
    if (isolateIds != null && !isolateIds.contains(isolateRef.id)) continue;
    final isolateGroupId = isolateOwnerGroup[isolateRef.id];
    if (isolateGroupId != null) {
      if (coveredIsolateGroups.contains(isolateGroupId)) continue;
      coveredIsolateGroups.add(isolateGroupId);
    }
    if (scopedOutput.isNotEmpty) {
      final scripts = await service.getScripts(isolateRef.id!);
      for (var script in scripts.scripts!) {
        final uri = Uri.parse(script.uri!);
        if (uri.scheme != 'package') continue;
        final scope = uri.path.split('/').first;
        // Skip scripts which should not be included in the report.
        if (!scopedOutput.contains(scope)) continue;
        final scriptReport = await service.getSourceReport(
            isolateRef.id!, <String>[SourceReportKind.kCoverage],
            forceCompile: true,
            scriptId: script.id,
            reportLines: reportLines ? true : null);
        final coverage = await _getCoverageJson(service, isolateRef,
            scriptReport, includeDart, functionCoverage, reportLines);
        allCoverage.addAll(coverage);
      }
    } else {
      final isolateReport = await service.getSourceReport(
        isolateRef.id!,
        <String>[SourceReportKind.kCoverage],
        forceCompile: true,
        reportLines: reportLines ? true : null,
      );
      final coverage = await _getCoverageJson(service, isolateRef,
          isolateReport, includeDart, functionCoverage, reportLines);
      allCoverage.addAll(coverage);
    }
  }
  return <String, dynamic>{'type': 'CodeCoverage', 'coverage': allCoverage};
}

Future _resumeIsolates(VmService service) async {
  final vm = await service.getVM();
  final futures = <Future>[];
  for (var isolateRef in vm.isolates!) {
    // Guard against sync as well as async errors: sync - when we are writing
    // message to the socket, the socket might be closed; async - when we are
    // waiting for the response, the socket again closes.
    futures.add(Future.sync(() async {
      final isolate = await service.getIsolate(isolateRef.id!);
      if (isolate.pauseEvent!.kind != EventKind.kResume) {
        await service.resume(isolateRef.id!);
      }
    }));
  }
  try {
    await Future.wait(futures);
  } catch (_) {
    // Ignore resume isolate failures
  }
}

Future _waitIsolatesPaused(VmService service, {Duration? timeout}) async {
  final pauseEvents = <String>{
    EventKind.kPauseStart,
    EventKind.kPauseException,
    EventKind.kPauseExit,
    EventKind.kPauseInterrupted,
    EventKind.kPauseBreakpoint
  };

  Future allPaused() async {
    final vm = await service.getVM();
    if (vm.isolates!.isEmpty) throw 'No isolates.';
    for (var isolateRef in vm.isolates!) {
      final isolate = await service.getIsolate(isolateRef.id!);
      if (!pauseEvents.contains(isolate.pauseEvent!.kind)) {
        throw 'Unpaused isolates remaining.';
      }
    }
  }

  return retry(allPaused, _retryInterval, timeout: timeout);
}

/// Returns the line number to which the specified token position maps.
///
/// Performs a binary search within the script's token position table to locate
/// the line in question.
int? _getLineFromTokenPos(Script script, int tokenPos) {
  // TODO(cbracken): investigate whether caching this lookup results in
  // significant performance gains.
  var min = 0;
  var max = script.tokenPosTable!.length;
  while (min < max) {
    final mid = min + ((max - min) >> 1);
    final row = script.tokenPosTable![mid];
    if (row[1] > tokenPos) {
      max = mid;
    } else {
      for (var i = 1; i < row.length; i += 2) {
        if (row[i] == tokenPos) return row.first;
      }
      min = mid + 1;
    }
  }
  return null;
}

Future<void> _processFunction(VmService service, IsolateRef isolateRef,
    Script script, FuncRef funcRef, HitMap hits) async {
  final func = await service.getObject(isolateRef.id!, funcRef.id!) as Func;
  final location = func.location;
  if (location != null) {
    final funcName = await _getFuncName(service, isolateRef, func);
    final tokenPos = location.tokenPos!;
    final line = _getLineFromTokenPos(script, tokenPos);

    if (line == null) {
      print('tokenPos $tokenPos has no line mapping for script ${script.uri!}');
      return;
    }
    hits.funcNames![line] = funcName;
  }
}

/// Returns a JSON coverage list backward-compatible with pre-1.16.0 SDKs.
Future<List<Map<String, dynamic>>> _getCoverageJson(
    VmService service,
    IsolateRef isolateRef,
    SourceReport report,
    bool includeDart,
    bool functionCoverage,
    bool reportLines) async {
  final hitMaps = <Uri, HitMap>{};
  final scripts = <ScriptRef, Script>{};
  final libraries = <LibraryRef>{};
  final needScripts = functionCoverage || !reportLines;
  for (var range in report.ranges!) {
    final scriptRef = report.scripts![range.scriptIndex!];
    final scriptUri = Uri.parse(report.scripts![range.scriptIndex!].uri!);

    // Not returned in scripts section of source report.
    if (scriptUri.scheme == 'evaluate') continue;

    // Skip scripts from dart:.
    if (!includeDart && scriptUri.scheme == 'dart') continue;

    // Look up the hit maps for this script (shared across isolates).
    final hits = hitMaps.putIfAbsent(scriptUri, () => HitMap());

    Script? script;
    if (needScripts) {
      if (!scripts.containsKey(scriptRef)) {
        scripts[scriptRef] =
            await service.getObject(isolateRef.id!, scriptRef.id!) as Script;
      }
      script = scripts[scriptRef];

      if (script == null) continue;
    }

    // If the script's library isn't loaded, load it then look up all its funcs.
    final libRef = script?.library;
    if (functionCoverage && libRef != null && !libraries.contains(libRef)) {
      hits.funcHits ??= <int, int>{};
      hits.funcNames ??= <int, String>{};
      libraries.add(libRef);
      final library =
          await service.getObject(isolateRef.id!, libRef.id!) as Library;
      if (library.functions != null) {
        for (var funcRef in library.functions!) {
          await _processFunction(service, isolateRef, script!, funcRef, hits);
        }
      }
      if (library.classes != null) {
        for (var classRef in library.classes!) {
          final clazz =
              await service.getObject(isolateRef.id!, classRef.id!) as Class;
          if (clazz.functions != null) {
            for (var funcRef in clazz.functions!) {
              await _processFunction(
                  service, isolateRef, script!, funcRef, hits);
            }
          }
        }
      }
    }

    // Collect hits and misses.
    final coverage = range.coverage;

    if (coverage == null) continue;

    for (final pos in coverage.hits!) {
      final line = reportLines ? pos : _getLineFromTokenPos(script!, pos);
      if (line == null) {
        print('tokenPos $pos has no line mapping for script $scriptUri');
        continue;
      }
      _incrementCountForKey(hits.lineHits, line);
      if (hits.funcNames != null && hits.funcNames!.containsKey(line)) {
        _incrementCountForKey(hits.funcHits!, line);
      }
    }
    for (final pos in coverage.misses!) {
      final line = reportLines ? pos : _getLineFromTokenPos(script!, pos);
      if (line == null) {
        print('tokenPos $pos has no line mapping for script $scriptUri');
        continue;
      }
      hits.lineHits.putIfAbsent(line, () => 0);
    }
    hits.funcNames?.forEach((line, funcName) {
      hits.funcHits?.putIfAbsent(line, () => 0);
    });
  }

  // Output JSON
  final coverage = <Map<String, dynamic>>[];
  hitMaps.forEach((uri, hits) {
    coverage.add(hitmapToJson(hits, uri));
  });
  return coverage;
}

void _incrementCountForKey(Map<int, int> counter, int key) {
  counter[key] = counter.containsKey(key) ? counter[key]! + 1 : 1;
}

Future<String> _getFuncName(
    VmService service, IsolateRef isolateRef, Func func) async {
  if (func.name == null) {
    return '${func.type}:${func.location!.tokenPos}';
  }
  final owner = func.owner;
  if (owner is ClassRef) {
    final cls = await service.getObject(isolateRef.id!, owner.id!) as Class;
    if (cls.name != null) return '${cls.name}.${func.name}';
  }
  return func.name!;
}

class StdoutLog extends Log {
  @override
  void warning(String message) => print(message);

  @override
  void severe(String message) => print(message);
}
