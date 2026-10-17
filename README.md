# Llama Local

A small native Omarchy / Quickshell bar plugin for an **existing local llama.cpp server**. Detect the server, see its model catalog, load or unload a model, and monitor tokens, RAM, VRAM, GPU power, utilization, and temperature.

Inspired by [omarchy-local-ai](https://github.com/sybil-solutions/omarchy-local-ai), with a narrower scope: connect to the llama.cpp instance you already run. Python standard library only; no Docker, downloads, proxy, telemetry, or background service.

## Install locally

Requires Omarchy's Quickshell shell with plugin support, Python 3, and a running `llama-server`. NVIDIA measurements additionally use `nvidia-smi`; AMD/Intel measurements use available DRM/hwmon sysfs sensors.

```sh
./install.sh
```

This links this directory into `~/.config/omarchy/plugins/strielok.llama-local` and enables its bar widget. Keep this directory in place. It does not alter or restart llama.cpp. Click **AI** in the bar to open the panel. The panel follows your Omarchy theme and supports scrolling, arrow keys, Enter, `x` to unload, `r` to refresh, and Escape.

For removal:

```sh
omarchy plugin disable strielok.llama-local
unlink ~/.config/omarchy/plugins/strielok.llama-local
omarchy-shell shell rescanPlugins
```

A published git repository with these files can also be installed with `omarchy plugin add <repository-url> --enable`.

## Server discovery and configuration

`auto` discovers your user's `llama-server` processes, prefers a router parent over worker processes, and reads its `--host` / `--port` arguments. If no process is found it tries `http://127.0.0.1:8080`. If you run multiple servers, containers, or configure their ports through environment variables, choose an explicit endpoint in the widget settings.

The bar entry in `~/.config/omarchy/shell.json` accepts:

```json
{"id": "strielok.llama-local", "endpoint": "http://127.0.0.1:8080", "pollSeconds": 3}
```

Only loopback endpoints are accepted. Requests ignore HTTP proxy variables and do not follow redirects. For an authenticated server, export `LLAMA_LOCAL_API_KEY` into the **Omarchy shell's environment** before it starts. Do not place credentials in the endpoint or widget settings.

The panel polls every 3 seconds when open (minimum 2) and every 15 seconds when closed. Polls do not overlap. Monitoring uses `autoload=false` and only queries stats for loaded models, so opening the panel never loads an idle model.

## Switching models

Switching uses llama.cpp's router API, `/models/load` and `/models/unload`. Run the server with `--models-preset /path/to/models.ini` or `--models-dir /path/to/models`. With `--models-max 1`, loading a different model replaces the resident one; with higher limits, the router may keep several loaded.

Loading a model **does not change clients' requested model IDs**. With autoload enabled, a client requesting another model can load that model again. This plugin manages residency, not a global client default. The catalog lists what the server exposes, not an unrelated scan of all GGUF files on disk.

Controls confirm the selected operation and refuse when an observed slot is generating or a model transition is in progress. New client requests can still race with that check; the router owns scheduling and eviction. If slot monitoring is disabled, controls fail rather than guessing whether it is safe to evict a model. The CLI serializes its own control operations with a file lock. A load request times out after 180 seconds; the server may still finish loading afterward, so refresh to check its state.

Single-model servers can be monitored, but require router mode for switching. The plugin never kills or restarts someone else's server.

## What the numbers mean

| Measurement | Source and scope |
| --- | --- |
| Prompt/output totals | Prometheus `/metrics`, since the current model process started; reset on unload/restart |
| Cached prompt tokens | Separate server counter, when available; excluded from processed prompt tokens |
| Generation throughput | Server-reported tokens/s over its metrics sampling bucket; may be zero while idle |
| Slot prompt / capacity | `/slots`: current or last prompt against slot context capacity, not exact live KV occupancy |
| llama.cpp RAM | Sum of RSS for the discovered server and its llama-server descendants; shared pages may count twice |
| System RAM | `/proc/meminfo`: total minus available |
| GPU power | Instantaneous watts for the whole GPU, including other applications; not model-specific power or total wall power |
| VRAM / utilization / temperature | Whole-device measurements, including other applications |

Unavailable measurements display **—**, never fabricated zeroes. Containerized or otherwise undiscoverable server process RAM may be unavailable even if HTTP works.

Enable token totals and throughput using `--metrics`. In a router preset file, add `metrics = true` under `[*]` so model workers inherit it, then reload/restart your server when convenient. Existing workers need to be recreated for the setting to take effect. Slot counts can be shown without metrics; if disabled, enable `--slots`. No prompts or generated content are collected or stored.

The **Token Activity** contribution chart shows 26 weeks of daily processed prompt + output tokens, with today's split and hover details. Color intensity is relative to the busiest displayed day; outlined cells mean no observations, while dim filled cells mean an observed zero. Cached prompt tokens are excluded.

History is saved per endpoint in `${XDG_STATE_HOME:-~/.local/state}/llama-local/usage.json` and survives shell restarts and model unloads. Each `status` poll records counter increases, dated in local time when observed. The first sample of a newly observed model establishes a baseline: existing totals cannot be dated reliably. Decreasing counters are treated as resets. Usage between polls, during downtime, or across undetected reloads can be missed; increments spanning midnight are assigned to the day observed. This is observed activity, not a complete billing ledger. No historical usage is backfilled, and no extra background service is installed.

## CLI and development

```sh
./bin/llama-local status
./bin/llama-local --endpoint http://127.0.0.1:8080 status
./bin/llama-local switch qwen3-coder
./bin/llama-local unload qwen3-coder
python3 -m unittest discover -s tests -v
./tests/qml-smoke.sh
```

CLI responses are JSON. A status snapshot reports offline/error state as data; rejected controls exit nonzero. Tests use a local mock router and never switch a real model. The QML smoke test loads the actual plugin in an isolated Quickshell process (panel closed; requires a Wayland session) with the installed Omarchy UI components.

API reference: [llama.cpp server](https://github.com/ggml-org/llama.cpp/tree/master/tools/server). The plugin was checked against the installed Omarchy shell and llama.cpp b11574; older router versions may not expose all stats.
