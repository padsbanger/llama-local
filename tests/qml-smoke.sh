#!/usr/bin/env bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
omarchy_shell_dir="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
ln -s -- "$omarchy_shell_dir/Commons" "$test_dir/Commons"
ln -s -- "$omarchy_shell_dir/Ui" "$test_dir/Ui"
ln -s -- "$omarchy_shell_dir/services" "$test_dir/services"
ln -s -- "$project_dir" "$test_dir/plugin"
if [[ "${1:-}" == "--interactions" ]]; then
  cp "$project_dir/tests/qml-interactions.qml" "$test_dir/shell.qml"
  marker=LLAMA_QML_INTERACTIONS_OK
else
  marker=LLAMA_QML_SMOKE_OK
cat > "$test_dir/shell.qml" <<'QML'
import QtQuick
import Quickshell
import "plugin"
ShellRoot {
  Panel { id: plugin }
  Timer {
    interval: 5000
    running: true
    onTriggered: {
      console.log("LLAMA_QML_SMOKE_OK models=" + plugin.models.length)
      Qt.quit()
    }
  }
}
QML
fi
QT_QPA_PLATFORM=wayland timeout 15 quickshell --no-color -p "$test_dir/shell.qml" > "$test_dir/log" 2>&1 || { cat "$test_dir/log"; exit 1; }
cat "$test_dir/log"
rg -q "$marker" "$test_dir/log"
if rg -q 'Failed to load|TypeError|ReferenceError|SyntaxError|Cannot assign|Unable to assign|is not a type|Binding loop' "$test_dir/log"; then
  exit 1
fi
