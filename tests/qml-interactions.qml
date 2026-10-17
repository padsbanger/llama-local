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
        function sample(t, count, task) {
          return { id: "test", state: "loaded", slots_available: true, slots_sample_time: t,
            metrics: { predicted_tokens_seconds: 0 },
            slots: [{ id: 0, task_id: task, busy: true, decoded_tokens: count }] }
        }
        var before = sample(100, 40, 1)
        var after = sample(103, 130, 1)
        check(plugin.generationRate(after, before) === 30, "Live rate must work while server gauge is zero")
        check(plugin.generationRate(after, null) === null, "First sample must not fabricate a rate")
        check(plugin.generationRate(sample(103, 200, 2), before) === null, "Task changes must rebaseline")
        check(plugin.generationRate(sample(103, 20, 1), before) === null, "Counter resets must rebaseline")
        check(plugin.generationRate(sample(100, 130, 1), before) === null, "Zero elapsed time must be rejected")
        check(plugin.generationRate(sample(200, 130, 1), before) === null, "Stale samples must be rejected")
        var missing = sample(103, null, 1)
        check(plugin.generationRate(missing, before) === null, "Missing progress must not become zero")
        check(plugin.generationText(sample(103, 0, 1)) === "Waiting for output", "Prefill must not imply stalled generation")
        check(plugin.generationText(after) === "Measuring…", "Unmeasured busy slot needs a clear label")
        before.slots.push({ id: 1, task_id: 2, busy: true, decoded_tokens: 10 })
        after.slots.push({ id: 1, task_id: 2, busy: true, decoded_tokens: 40 })
        check(plugin.generationRate(after, before) === 40, "Concurrent slot rates must be summed")
        fixture([before])
        plugin.applySnapshot({ online: true, endpoint: plugin.snapshot.endpoint, models: [after] })
        check(plugin.models[0].generation_tps === 40, "Snapshot must attach the computed live rate")
        plugin.applySnapshot({ online: true, endpoint: "http://127.0.0.1:2", models: [sample(106, 220, 1)] })
        check(plugin.models[0].generation_tps === null, "Endpoint changes must rebaseline")
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
