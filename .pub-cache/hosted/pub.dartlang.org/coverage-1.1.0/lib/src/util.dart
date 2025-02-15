// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

// TODO(cbracken) make generic
/// Retries the specified function with the specified interval and returns
/// the result on successful completion.
Future<dynamic> retry(Future Function() f, Duration interval,
    {Duration? timeout}) async {
  var keepGoing = true;

  Future<dynamic> _withTimeout(Future Function() f, {Duration? duration}) {
    if (duration == null) {
      return f();
    }

    return f().timeout(duration, onTimeout: () {
      keepGoing = false;
      final msg = duration.inSeconds == 0
          ? '${duration.inMilliseconds}ms'
          : '${duration.inSeconds}s';
      throw StateError('Failed to complete within $msg');
    });
  }

  return _withTimeout(() async {
    while (keepGoing) {
      try {
        return await f();
      } catch (_) {
        if (keepGoing) {
          await Future<dynamic>.delayed(interval);
        }
      }
    }
  }, duration: timeout);
}

/// Scrapes and returns the observatory URI from a string, or null if not found.
///
/// Potentially useful as a means to extract it from log statements.
Uri? extractObservatoryUri(String str) {
  const kObservatoryListening = 'Observatory listening on ';
  final msgPos = str.indexOf(kObservatoryListening);
  if (msgPos == -1) return null;
  final startPos = msgPos + kObservatoryListening.length;
  final endPos = str.indexOf(RegExp(r'(\s|$)'), startPos);
  try {
    return Uri.parse(str.substring(startPos, endPos));
  } on FormatException {
    return null;
  }
}

/// Returns an open port by creating a temporary Socket
Future<int> getOpenPort() async {
  ServerSocket socket;

  try {
    socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  } catch (_) {
    // try again v/ V6 only. Slight possibility that V4 is disabled
    socket =
        await ServerSocket.bind(InternetAddress.loopbackIPv6, 0, v6Only: true);
  }

  try {
    return socket.port;
  } finally {
    await socket.close();
  }
}

const muliLineIgnoreStart = '// coverage:ignore-start';
const muliLineIgnoreEnd = '// coverage:ignore-end';
const singleLineIgnore = '// coverage:ignore-line';
const ignoreFile = '// coverage:ignore-file';

/// Return list containing inclusive range of lines to be ignored by coverage.
/// If there is a error in balancing the statements it will ignore nothing,
/// unless `coverage:ignore-file` is found.
/// Return [0, lines.length] if the whole file is ignored.
///
/// ```
/// 1.  final str = ''; // coverage:ignore-line
/// 2.  final str = '';
/// 3.  final str = ''; // coverage:ignore-start
/// 4.  final str = '';
/// 5.  final str = ''; // coverage:ignore-end
/// ```
///
/// Returns
/// ```
/// [
///   [1,1],
///   [3,5],
/// ]
/// ```
///
List<List<int>> getIgnoredLines(List<String>? lines) {
  final ignoredLines = <List<int>>[];
  if (lines == null) return ignoredLines;

  final allLines = [
    [0, lines.length]
  ];

  var isError = false;
  var i = 0;
  while (i < lines.length) {
    if (lines[i].contains(ignoreFile)) return allLines;

    if (lines[i].contains(muliLineIgnoreEnd)) isError = true;

    if (lines[i].contains(singleLineIgnore)) ignoredLines.add([i + 1, i + 1]);

    if (lines[i].contains(muliLineIgnoreStart)) {
      final start = i;
      ++i;
      while (i < lines.length) {
        if (lines[i].contains(ignoreFile)) return allLines;
        if (lines[i].contains(muliLineIgnoreStart)) {
          isError = true;
          break;
        }

        if (lines[i].contains(muliLineIgnoreEnd)) {
          ignoredLines.add([start + 1, i + 1]);
          break;
        }
        ++i;
      }
    }
    ++i;
  }

  return isError ? [] : ignoredLines;
}
