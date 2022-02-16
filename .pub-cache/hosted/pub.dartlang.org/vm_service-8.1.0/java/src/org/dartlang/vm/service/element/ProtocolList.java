/*
 * Copyright (c) 2015, the Dart project authors.
 *
 * Licensed under the Eclipse Public License v1.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 *
 * http://www.eclipse.org/legal/epl-v10.html
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */
package org.dartlang.vm.service.element;

// This is a generated file.

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;

/**
 * A {@link ProtocolList} contains a list of all protocols supported by the service instance.
 */
@SuppressWarnings({"WeakerAccess", "unused"})
public class ProtocolList extends Response {

  public ProtocolList(JsonObject json) {
    super(json);
  }

  /**
   * A list of supported protocols provided by this service.
   */
  public ElementList<Protocol> getProtocols() {
    return new ElementList<Protocol>(json.get("protocols").getAsJsonArray()) {
      @Override
      protected Protocol basicGet(JsonArray array, int index) {
        return new Protocol(array.get(index).getAsJsonObject());
      }
    };
  }
}
