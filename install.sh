#!/usr/bin/env bash
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/strielok.llama-local"
command -v python3 >/dev/null
command -v omarchy-shell >/dev/null
command -v omarchy >/dev/null
mkdir -p -- "$(dirname -- "$plugin_dir")"
if [[ -e "$plugin_dir" || -L "$plugin_dir" ]]; then
  if [[ "$(readlink -f -- "$plugin_dir")" != "$source_dir" ]]; then
    echo "Refusing to overwrite existing plugin: $plugin_dir" >&2
    exit 1
  fi
else
  ln -s -- "$source_dir" "$plugin_dir"
fi
omarchy-shell shell rescanPlugins
# Discovery is asynchronous; wait until the manifest is visible to the shell.
for attempt in {1..50}; do
  if omarchy-shell shell listPlugins | python3 -c 'import json,sys; sys.exit(not any(p["id"] == "strielok.llama-local" for p in json.load(sys.stdin)))'; then
    omarchy plugin enable strielok.llama-local
    exit 0
  fi
  sleep 0.1
done
echo "Plugin linked, but the shell did not discover it. Check omarchy-shell logs." >&2
exit 1
