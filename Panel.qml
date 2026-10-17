import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "strielok.llama-omarchy"
  ipcTarget: "strielok.llama-omarchy"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string cli: decodeURIComponent(String(Qt.resolvedUrl("bin/llama-omarchy")).replace(/^file:\/\//, ""))
  readonly property string endpoint: String(setting("endpoint", "auto"))
  readonly property var models: snapshot.models || []
  readonly property var activeModels: models.filter(function(m) { return m.state === "loaded" })
  readonly property string serverStatus: {
    if (operation.running) return operationAction === "switch" ? "Loading" : "Unloading"
    if (!snapshot.online) return "Offline"
    if (models.some(function(m) { return m.state === "loading" || m.state === "downloading" })) return "Loading"
    if (models.some(function(m) { return m.state === "unloading" })) return "Unloading"
    if (activeModels.some(function(m) { return (m.slots || []).some(function(s) { return s.busy }) })) return "Working"
    if (!activeModels.length) return "Standby"
    if (activeModels.some(function(m) { return !m.slots || (m.notes || []).some(function(n) { return n.indexOf("Slot information unavailable") === 0 }) })) return "Unknown"
    return "Idle"
  }
  readonly property bool serverWorking: ["Working", "Loading", "Unloading"].indexOf(serverStatus) >= 0
  readonly property color ink: Color.foreground
  readonly property color muted: Util.alpha(ink, 0.65)
  property var snapshot: ({ online: false, router: false, models: [] })
  property string problem: ""
  property string notice: ""
  property string pendingModel: ""
  property string pendingAction: ""
  property string selectedModel: ""
  readonly property int selectedIndex: models.findIndex(function(m) { return m.id === selectedModel })
  property string expandedModel: ""
  property string operationModel: ""
  property string operationAction: ""
  property bool refreshQueued: false
  readonly property var usage: snapshot.usage || ({ days: [] })
  readonly property var usageDays: usage.days || []
  readonly property real usagePeak: Math.max(1, ...usageDays.map(function(d) { return d.total || 0 }))
  property string hoveredDay: ""

  function activityColor(total) {
    if (total === null || total === undefined) return "transparent"
    if (total === 0) return Util.alpha(ink, 0.08)
    return Util.alpha(Color.accent, 0.25 + 0.75 * Math.ceil(4 * total / usagePeak) / 4)
  }

  function amount(value, suffix, decimals) {
    return value === undefined || value === null ? "—" : Number(value).toLocaleString(Qt.locale(), "f", decimals || 0) + (suffix || "")
  }
  function bytes(value) { return value === undefined || value === null ? "—" : amount(value / 1073741824, " GiB", 1) }
  function refresh() {
    if (poll.running) { refreshQueued = true; return }
    poll.requestEndpoint = endpoint
    poll.command = ["python3", cli, "--endpoint", endpoint, "status"]
    poll.running = true
  }
  function actionReason(model, action) {
    if (!model) return "Select a model."
    if (operation.running) return "Wait for the current operation."
    if (!snapshot.online) return "Server is unavailable."
    if (!snapshot.router) return "Switching requires router mode."
    if (models.some(function(m) { return ["loading", "downloading", "unloading"].indexOf(m.state) >= 0 }))
      return "Wait for the model transition to finish."
    if (action === "switch" && ["unloaded", "sleeping"].indexOf(model.state) < 0)
      return model.state === "loaded" ? "Model is already loaded." : "Model cannot be loaded in its current state."
    if (action === "unload" && model.state !== "loaded") return "Model is not loaded."
    var affected = activeModels.filter(function(m) { return action === "switch" || m.id === model.id })
    if (affected.some(function(m) { return (m.slots || []).some(function(slot) { return slot.busy }) }))
      return "Model is generating. Wait for the request to finish."
    if (affected.some(function(m) { return (m.notes || []).some(function(n) { return n.indexOf("Slot information unavailable") === 0 }) }))
      return "Slot information is unavailable; cannot verify whether the model is busy."
    return ""
  }
  function revealSelection() {
    var row = modelRows.itemAt(selectedIndex)
    if (!row) return
    var y = row.mapToItem(content, 0, 0).y
    scroll.contentY = Math.max(0, Math.min(y, scroll.contentHeight - scroll.height))
  }
  function choose(model, action) {
    var reason = actionReason(model, action)
    if (reason) { problem = reason; pendingModel = ""; return }
    selectedModel = model.id
    pendingModel = model.id
    pendingAction = action
    problem = ""
    notice = ""
    Qt.callLater(revealSelection)
  }
  function execute() {
    var model = models.find(function(m) { return m.id === pendingModel })
    var reason = actionReason(model, pendingAction)
    if (reason) { problem = reason; pendingModel = ""; return }
    operation.command = ["python3", cli, "--endpoint", snapshot.endpoint, pendingAction, pendingModel]
    operationModel = pendingModel
    operationAction = pendingAction
    notice = ""
    pendingModel = ""
    operation.running = true
  }
  function activateSelected() {
    if (pendingModel) { execute(); return }
    var model = models[selectedIndex]
    if (model && model.state === "loaded") {
      expandedModel = expandedModel === model.id ? "" : model.id
      Qt.callLater(revealSelection)
    } else choose(model, "switch")
  }
  function move(delta) {
    if (!models.length) return
    pendingModel = ""
    selectedModel = models[(selectedIndex + delta + models.length) % models.length].id
    Qt.callLater(revealSelection)
  }
  onSelectedModelChanged: if (pendingModel && pendingModel !== selectedModel) pendingModel = ""
  onModelsChanged: {
    if (!models.some(function(m) { return m.id === selectedModel }))
      selectedModel = models.length ? models[0].id : ""
    if (pendingModel && !models.some(function(m) { return m.id === pendingModel })) pendingModel = ""
  }
  onOpenedChanged: { if (opened) refresh(); else pendingModel = "" }
  onEndpointChanged: Qt.callLater(function() { root.snapshot = ({ online: false, router: false, models: [] }); root.pendingModel = ""; root.refresh() })

  Process {
    id: poll
    property string requestEndpoint: ""
    stdout: StdioCollector { id: pollOut; waitForEnd: true }
    stderr: StdioCollector { id: pollErr; waitForEnd: true }
    onExited: function(code) {
      try {
        if (poll.requestEndpoint !== root.endpoint) { root.refreshQueued = false; Qt.callLater(root.refresh); return }
        var result = JSON.parse(pollOut.text)
        if (code !== 0) throw new Error(result.error || "Status command failed")
        root.snapshot = result
      } catch (e) {
        root.snapshot = ({ online: false, error: "Monitor failed: " + e.message, models: [] })
      }
      if (root.refreshQueued) { root.refreshQueued = false; Qt.callLater(root.refresh) }
    }
  }
  Process {
    id: operation
    stdout: StdioCollector { id: opOut; waitForEnd: true }
    stderr: StdioCollector { id: opErr; waitForEnd: true }
    onExited: function(code) {
      try {
        var result = JSON.parse(opOut.text)
        if (code !== 0 || !result.success) throw new Error(result.error || "Operation failed")
        root.notice = result.message
      } catch (e) { root.problem = e.message; root.notice = "" }
      root.refresh()
    }
  }
  Timer {
    interval: root.opened ? Math.max(2, Number(root.setting("pollSeconds", 3)) || 3) * 1000 : 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasVisualContent: true
    labelVisible: false
    fixedWidth: vertical ? barSize : barContents.implicitWidth + scaledHorizontalMargin * 2
    fixedHeight: vertical ? Style.space(28) + scaledVerticalPadding * 2 : barSize
    tooltipText: "llama.cpp · " + root.serverStatus + "\n" + (root.activeModels.map(function(m) { return m.id }).join(", ") || root.snapshot.error || "No model loaded")
    Row {
      id: barContents
      anchors.centerIn: parent
      spacing: Style.space(6)
      Image {
        id: llamaLogo
        width: Style.space(24)
        height: width
        anchors.verticalCenter: parent.verticalCenter
        source: Qt.resolvedUrl("assets/llama.cpp.svg")
        sourceSize.width: width * 2
        sourceSize.height: height * 2
        fillMode: Image.PreserveAspectFit
        layer.enabled: true
        layer.effect: MultiEffect {
          colorization: 1.0
          colorizationColor: button.foreground
        }
        opacity: root.serverStatus === "Offline" ? 0.45 : 1
      }
      Rectangle {
        id: statusDot
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(6)
        height: width
        radius: width / 2
        color: root.serverStatus === "Offline" ? Color.urgent : root.serverWorking ? Color.accent : root.serverStatus === "Idle" ? button.foreground : "transparent"
        border.width: root.serverStatus === "Standby" || root.serverStatus === "Unknown" ? 1 : 0
        border.color: button.foreground
        visible: !button.vertical
      }
      Text {
        visible: !button.vertical
        anchors.verticalCenter: parent.verticalCenter
        text: root.serverStatus
        textFormat: Text.PlainText
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
      }
    }
    Rectangle {
      visible: button.vertical
      anchors.right: barContents.right
      anchors.bottom: barContents.bottom
      width: Style.space(6)
      height: width
      radius: width / 2
      color: statusDot.color
      border.width: statusDot.border.width
      border.color: statusDot.border.color
    }
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    padding: 0
    contentWidth: fittedContentWidth(Style.space(420))
    contentHeight: fittedContentHeight(content.height + Style.space(32), screen ? screen.height - Style.space(100) : 720)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onCloseRequested: { if (root.pendingModel) root.pendingModel = ""; else root.close() }
      onMoveRequested: function(dx, dy) { root.move(dy || dx) }
      onTabRequested: function(direction) { root.move(direction) }
      onActivateRequested: root.activateSelected()
      onDeleteRequested: root.choose(root.models[root.selectedIndex], "unload")
      onTextKey: function(text) { if (text === "r") root.refresh() }

      Flickable {
        id: scroll
        anchors.fill: parent
        clip: true
        contentHeight: content.height + Style.space(32)
        boundsBehavior: Flickable.StopAtBounds
        Column {
          id: content
          x: Style.space(20)
          y: Style.space(16)
          width: scroll.width - Style.space(40)
          spacing: Style.space(12)

          RowLayout {
            width: parent.width
            Column {
              Layout.fillWidth: true
              spacing: Style.space(4)
              Label { text: "LLAMA OMARCHY"; font.bold: true; font.pixelSize: Style.font.body + 3 }
              Label { text: root.snapshot.online ? (root.snapshot.router ? "Connected · router" : "Connected · single model") : "Server offline"; color: root.snapshot.online ? Color.accent : root.muted }
            }
            Button { text: "↻"; tooltipText: "Refresh (r)"; enabled: !poll.running; onClicked: root.refresh() }
          }
          Label { width: parent.width; text: root.snapshot.endpoint || root.endpoint; color: root.muted; elide: Text.ElideMiddle }
          Label { width: parent.width; visible: text !== ""; text: root.problem || root.snapshot.error || ""; color: Color.urgent; wrapMode: Text.Wrap }
          Label { width: parent.width; visible: text !== ""; text: root.notice; wrapMode: Text.Wrap }
          Rule {}
          Label { text: "MODELS"; color: root.muted }
          Label { width: parent.width; visible: !root.models.length; text: "No models found. Start llama-server or check the endpoint in widget settings."; wrapMode: Text.Wrap }
          Repeater {
            id: modelRows
            model: root.models
            delegate: Rectangle {
              id: modelRow
              required property var modelData
              required property int index
              readonly property var metrics: modelData.metrics || ({})
              readonly property bool loaded: modelData.state === "loaded"
              readonly property bool busy: (modelData.slots || []).some(function(s) { return s.busy })
              readonly property string loadReason: root.actionReason(modelData, "switch")
              readonly property string unloadReason: root.actionReason(modelData, "unload")
              width: content.width
              height: modelBody.height + Style.space(16)
              radius: Style.cornerRadius
              color: Util.alpha(root.ink, root.selectedIndex === index ? 0.10 : 0.04)
              border.width: root.selectedIndex === index ? 1 : 0
              border.color: Util.alpha(root.ink, 0.25)
              Column {
                id: modelBody
                x: Style.space(10); y: Style.space(8)
                width: parent.width - Style.space(20)
                spacing: Style.space(6)
                Label { width: parent.width; text: modelRow.modelData.id; elide: Text.ElideMiddle; font.bold: true }
                RowLayout {
                  width: parent.width
                  Label {
                    Layout.fillWidth: true
                    text: modelRow.modelData.failed ? "Failed to load" : modelRow.loaded ? (modelRow.busy ? "Generating" : "Loaded · idle") : modelRow.modelData.state
                    color: modelRow.modelData.state === "loaded" ? Color.accent : root.muted
                  }
                  Button {
                    visible: !!root.snapshot.router && modelRow.modelData.state === "loaded"
                    text: "Unload"; enabled: modelRow.unloadReason === ""
                    tooltipText: modelRow.unloadReason
                    onClicked: { root.selectedModel = modelRow.modelData.id; root.choose(modelRow.modelData, "unload") }
                  }
                  Button {
                    visible: !!root.snapshot.router && modelRow.modelData.state !== "loaded"
                    text: "Load"; enabled: modelRow.loadReason === ""
                    tooltipText: modelRow.loadReason
                    onClicked: { root.selectedModel = modelRow.modelData.id; root.choose(modelRow.modelData, "switch") }
                  }
                }
                Stat {
                  visible: modelRow.loaded
                  label: "Generation throughput"
                  value: root.amount(modelRow.metrics.predicted_tokens_seconds, " tok/s", 1)
                }
                Label {
                  width: parent.width
                  visible: operation.running && root.operationModel === modelRow.modelData.id
                  text: root.operationAction === "switch" ? "Loading…" : "Unloading…"
                  color: Color.accent
                }
                Column {
                  width: parent.width
                  visible: root.pendingModel === modelRow.modelData.id
                  spacing: Style.space(8)
                  Label {
                    width: parent.width
                    text: root.pendingAction === "switch" ? "Load this model? The router may evict another model. Clients still choose their own model ID." : "Unload this model and free its memory?"
                    wrapMode: Text.Wrap
                  }
                  Label {
                    width: parent.width
                    text: root.actionReason(modelRow.modelData, root.pendingAction)
                    visible: text !== ""
                    color: root.muted
                    wrapMode: Text.Wrap
                  }
                  Row {
                    spacing: Style.space(8)
                    Button {
                      text: "Confirm"; bordered: true
                      enabled: root.actionReason(modelRow.modelData, root.pendingAction) === ""
                      tooltipText: root.actionReason(modelRow.modelData, root.pendingAction)
                      onClicked: root.execute()
                    }
                    Button { text: "Cancel"; onClicked: root.pendingModel = "" }
                  }
                }
                Button {
                  visible: modelRow.loaded
                  text: root.expandedModel === modelRow.modelData.id ? "Hide details" : "Show details"
                  onClicked: {
                    root.selectedModel = modelRow.modelData.id
                    root.expandedModel = root.expandedModel === modelRow.modelData.id ? "" : modelRow.modelData.id
                  }
                }
                Column {
                  width: parent.width
                  visible: modelRow.loaded && root.expandedModel === modelRow.modelData.id
                  spacing: Style.space(8)
                  Stat { label: "Prompt tokens processed"; value: root.amount(modelRow.metrics.prompt_tokens_total) }
                  Stat { label: "Prompt tokens cached"; value: root.amount(modelRow.metrics.prompt_tokens_cached_total) }
                  Stat { label: "Output tokens"; value: root.amount(modelRow.metrics.tokens_predicted_total) }
                  Repeater {
                    model: modelRow.modelData.slots || []
                    delegate: Column {
                      required property var modelData
                      width: modelBody.width
                      spacing: Style.space(5)
                      Stat { label: "Slot " + parent.modelData.id + (parent.modelData.busy ? " · generating" : " · idle"); value: root.amount(parent.modelData.prompt_tokens) + " / " + root.amount(parent.modelData.context_size) }
                      Rectangle {
                        width: parent.width; height: Style.space(4); radius: height / 2
                        color: Util.alpha(root.ink, 0.10)
                        Rectangle { width: parent.width * Math.min(1, (modelData.prompt_tokens || 0) / Math.max(1, modelData.context_size || 1)); height: parent.height; radius: height / 2; color: Color.accent }
                      }
                    }
                  }
                  Label { width: parent.width; text: "Counters since model load. Slot bars show current / last prompt against context capacity."; color: root.muted; wrapMode: Text.Wrap }
                  Repeater {
                    model: modelRow.modelData.notes || []
                    delegate: Label { required property string modelData; width: modelBody.width; text: modelData; color: root.muted; wrapMode: Text.Wrap }
                  }
                }
              }
            }
          }
          Rule {}
          Label { width: parent.width; visible: !!root.snapshot.online && !root.snapshot.router; text: "Switching requires router mode (--models-preset or --models-dir)."; color: root.muted; wrapMode: Text.Wrap }
          Column {
            id: activity
            width: parent.width
            spacing: Style.space(8)
            readonly property real cell: Math.max(1, (width - Style.space(28) - 25 * Style.space(3)) / 26)
            RowLayout {
              width: parent.width
              Label { Layout.fillWidth: true; text: "TOKEN ACTIVITY"; color: root.muted }
              Label { text: "26 weeks"; color: root.muted }
            }
            Label {
              width: parent.width
              text: root.amount(root.usage.total) + " tokens observed"
              font.bold: true
            }
            Stat {
              label: "Today · prompt / output"
              value: root.amount(root.usage.today ? root.usage.today.prompt : null) + " / " + root.amount(root.usage.today ? root.usage.today.output : null)
            }
            Row {
              x: Style.space(28)
              spacing: Style.space(3)
              Repeater {
                model: root.usageDays.length ? 26 : 0
                delegate: Item {
                  required property int index
                  width: activity.cell
                  height: Style.font.body + Style.space(4)
                  Label {
                    readonly property string day: root.usageDays[parent.index * 7].date
                    visible: parent.index === 0 || day.slice(5, 7) !== root.usageDays[(parent.index - 1) * 7].date.slice(5, 7)
                    text: Qt.formatDate(new Date(Number(day.slice(0, 4)), Number(day.slice(5, 7)) - 1, Number(day.slice(8, 10))), "MMM")
                    color: root.muted
                    font.pixelSize: Style.font.body - 2
                  }
                }
              }
            }
            Row {
              spacing: Style.space(4)
              Column {
                width: Style.space(24)
                spacing: Style.space(3)
                Repeater {
                  model: ["M", "", "W", "", "F", "", ""]
                  delegate: Label {
                    required property string modelData
                    height: activity.cell
                    text: modelData
                    color: root.muted
                    font.pixelSize: Style.font.body - 3
                    verticalAlignment: Text.AlignVCenter
                  }
                }
              }
              Grid {
                rows: 7
                flow: Grid.TopToBottom
                spacing: Style.space(3)
                Repeater {
                  model: root.usageDays
                  delegate: Rectangle {
                    required property var modelData
                    width: activity.cell; height: activity.cell
                    radius: Style.space(2)
                    color: root.activityColor(modelData.total)
                    // Keep future cells in the grid so weeks stay aligned.
                    opacity: modelData.future ? 0 : 1
                    border.width: 1
                    border.color: dayMouse.containsMouse ? root.ink : Util.alpha(root.ink, 0.12)
                    MouseArea {
                      id: dayMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      enabled: !parent.modelData.future
                      onEntered: root.hoveredDay = parent.modelData.date
                      onExited: root.hoveredDay = ""
                    }
                  }
                }
              }
            }
            RowLayout {
              width: parent.width
              Label { Layout.fillWidth: true; text: "Daily prompt + output"; color: root.muted; font.pixelSize: Style.font.body - 2 }
              Label { text: "Less"; color: root.muted; font.pixelSize: Style.font.body - 2 }
              Repeater {
                model: [0, 0.25, 0.5, 0.75, 1]
                delegate: Rectangle {
                  required property real modelData
                  width: activity.cell; height: activity.cell; radius: Style.space(2)
                  color: root.activityColor(modelData * root.usagePeak)
                }
              }
              Label { text: "More"; color: root.muted; font.pixelSize: Style.font.body - 2 }
            }
            Label {
              width: parent.width
              wrapMode: Text.Wrap
              color: root.muted
              text: {
                var day = root.usageDays.find(function(d) { return d.date === root.hoveredDay })
                if (day) return day.date + (day.total === null ? " · No observations" : " · " + root.amount(day.prompt) + " prompt + " + root.amount(day.output) + " output")
                return root.usage.error || (root.usage.observing ? "Hover a day for details. Outlined days have no observations." : "Waiting for token metrics. Enable --metrics on loaded models.")
              }
            }
          }
          Rule {}
          Label { text: "MEMORY"; color: root.muted }
          Stat { label: "llama.cpp process RAM (RSS)"; value: root.bytes((root.snapshot.memory || {}).server_rss_bytes) }
          Stat { label: "System RAM"; value: root.bytes((root.snapshot.memory || {}).used_bytes) + " / " + root.bytes((root.snapshot.memory || {}).total_bytes) }
          Repeater {
            model: root.snapshot.gpus || []
            delegate: Column {
              id: gpu
              required property var modelData
              width: content.width
              spacing: Style.space(8)
              Rule {}
              Label { width: parent.width; text: gpu.modelData.name; font.bold: true; wrapMode: Text.Wrap }
              Stat { label: "Power · whole device"; value: root.amount(gpu.modelData.power_w, " W", 1) }
              Stat { label: "VRAM · whole device"; value: root.bytes(gpu.modelData.vram_used_bytes) + " / " + root.bytes(gpu.modelData.vram_total_bytes) }
              Stat { label: "Utilization / temperature"; value: root.amount(gpu.modelData.util_percent, "%") + " / " + root.amount(gpu.modelData.temperature_c, " °C") }
            }
          }
          Label { width: parent.width; visible: !(root.snapshot.gpus || []).length; text: "GPU sensors unavailable. Missing measurements appear as —."; color: root.muted; wrapMode: Text.Wrap }
          Rule {}
          Label { width: parent.width; text: "↑↓ select · Enter load / details · x unload · r refresh · Esc cancel / close"; color: root.muted; wrapMode: Text.Wrap }
        }
      }
    }
  }
  component Label: Text {
    textFormat: Text.PlainText
    color: root.ink
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
  component Rule: Rectangle {
    width: parent.width
    height: 1
    color: Util.alpha(root.ink, 0.13)
  }
  component Stat: RowLayout {
    property string label: ""
    property string value: ""
    width: parent.width
    Label { Layout.fillWidth: true; text: parent.label; color: root.muted; wrapMode: Text.Wrap }
    Label { text: parent.value }
  }
}
