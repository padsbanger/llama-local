# Development workflow

After completing plugin changes, run the relevant checks, rebuild if a build step
exists, and restart the plugin before reporting completion. This project uses
QML and Python directly, so there is currently no separate build step. Restart
the hosting shell with `omarchy restart shell`, then verify the plugin responds
to IPC (for example, `omarchy-shell strielok.llama-omarchy close`).
