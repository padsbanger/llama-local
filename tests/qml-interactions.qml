import QtQuick
import Quickshell
import "plugin"

ShellRoot {
  Panel {
    id: plugin
    manageIpc: false
    // Keep this fixture isolated from real servers and usage history.
    function refresh() {}
  }
  function check(condition, message) {
    if (!condition) throw new Error(message)
  }
  function fixture(models, router) {
    plugin.snapshot = { online: true, router: router === undefined ? true : router,
      endpoint: "http://127.0.0.1:1", models: models }
  }
  Timer {
    interval: 100
    running: true
    onTriggered: {
      try {
        var a = { id: "loaded-model-with-a-long-name-for-layout-testing", state: "loaded",
          metrics: { tokens_predicted_total: 1234, predicted_tokens_seconds: 42.5 },
          slots: [{ id: 0, busy: false, prompt_tokens: 100, context_size: 8192 }] }
        var b = { id: "unloaded-model", state: "unloaded" }
        fixture([a, b])
        check(plugin.serverStatus === "Idle", "Loaded idle slots must show Idle")
        fixture([b])
        check(plugin.serverStatus === "Standby", "No resident model must show Standby")
        plugin.snapshot = { online: false, models: [] }
        check(plugin.serverStatus === "Offline", "Offline server must show Offline")
        fixture([a, b])
        plugin.selectedModel = b.id
        fixture([b, a])
        check(plugin.selectedIndex === 0 && plugin.selectedModel === b.id, "Selection must follow model ID")
        plugin.activateSelected()
        check(plugin.pendingModel === b.id, "Enter must request load for an unloaded model")
        plugin.move(1)
        check(plugin.pendingModel === "" && plugin.selectedModel === a.id, "Moving must cancel confirmation")
        plugin.activateSelected()
        check(plugin.expandedModel === a.id && plugin.pendingModel === "", "Enter must expand a loaded model")
        plugin.choose(b, "unload")
        check(plugin.pendingModel === "", "Cannot unload an unloaded model")
        plugin.choose(a, "switch")
        check(plugin.pendingModel === "", "Cannot load a loaded model")
        fixture([a, b], false)
        check(plugin.actionReason(a, "unload") !== "", "Single-model server must reject controls")
        fixture([a, b])
        plugin.choose(b, "switch")
        check(plugin.pendingModel === b.id, "Idle router must allow load")
        var busy = Object.assign({}, a, { slots: [{ busy: true }] })
        fixture([busy, b])
        check(plugin.serverStatus === "Working", "Busy slots must show Working")
        check(plugin.actionReason(b, "switch") !== "", "Busy model must block load")
        plugin.execute()
        check(plugin.pendingModel === "" && plugin.problem.indexOf("generating") >= 0,
          "Confirm must recheck eligibility before starting a command")
        var unknown = Object.assign({}, a, { notes: ["Slot information unavailable (enable --slots)."] })
        fixture([unknown, b])
        check(plugin.serverStatus === "Unknown", "Missing slot monitoring must not imply Idle")
        check(plugin.actionReason(a, "unload") !== "", "Unavailable slots must block unload")
        fixture([a, { id: b.id, state: "loading" }])
        check(plugin.serverStatus === "Loading", "Model transition must show Loading")
        check(plugin.actionReason(a, "unload") !== "", "Transitions must block controls")
        fixture([a, b])
        plugin.choose(b, "switch")
        fixture([a])
        check(plugin.selectedModel === a.id && plugin.pendingModel === "", "Removed models must clear pending action")
        fixture([a, b])
        plugin.problem = ""
        plugin.choose(a, "unload")
        plugin.open()
        finish.start()
      } catch (error) {
        console.error("LLAMA_QML_INTERACTIONS_FAILED: " + error.message)
        Qt.quit()
      }
    }
  }
  Timer {
    id: finish
    interval: 500
    onTriggered: {
      plugin.close()
      check(plugin.pendingModel === "", "Closing must cancel confirmation")
      console.log("LLAMA_QML_INTERACTIONS_OK")
      Qt.quit()
    }
  }
}
