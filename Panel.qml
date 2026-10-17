import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "strielok.llama-local"
  ipcTarget: "strielok.llama-local"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string cli: decodeURIComponent(String(Qt.resolvedUrl("bin/llama-local")).replace(/^file:\/\//, ""))
  readonly property string endpoint: String(setting("endpoint", "auto"))
  readonly property var models: snapshot.models || []
  readonly property var activeModels: models.filter(function(m) { return m.state === "loaded" })
  readonly property color ink: Color.foreground
  readonly property color muted: Util.alpha(ink, 0.65)
  property var snapshot: ({ online: false, router: false, models: [] })
  property string problem: ""
  property string notice: ""
  property string pendingModel: ""
  property string pendingAction: ""
  property int selectedIndex: 0
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
  function choose(model, action) {
    if (operation.running || !snapshot.router || !model) return
    pendingModel = model.id
    pendingAction = action
    problem = ""
    notice = ""
  }
  function execute() {
    if (operation.running || !pendingModel) return
    operation.command = ["python3", cli, "--endpoint", snapshot.endpoint, pendingAction, pendingModel]
    notice = (pendingAction === "switch" ? "Loading " : "Unloading ") + pendingModel + "…"
    pendingModel = ""
    operation.running = true
  }
  function move(delta) {
    if (!models.length) return
    selectedIndex = (selectedIndex + delta + models.length) % models.length
    var row = modelRows.itemAt(selectedIndex)
    if (row) {
      var y = row.mapToItem(content, 0, 0).y
      scroll.contentY = Math.max(0, Math.min(y - 80, scroll.contentHeight - scroll.height))
    }
  }
  onOpenedChanged: if (opened) refresh()
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
        root.selectedIndex = Math.min(root.selectedIndex, Math.max(0, root.models.length - 1))
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
    text: root.bar && root.bar.vertical ? "AI" : "AI · " + (operation.running ? "…" : root.snapshot.online ? (root.activeModels.length ? "" + root.activeModels.length : "idle") : "off")
    dimmed: !root.snapshot.online
    tooltipText: "Llama Local\n" + (root.activeModels.map(function(m) { return m.id }).join(", ") || root.snapshot.error || "No model loaded")
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
      onActivateRequested: {
        if (root.pendingModel) root.execute()
        else root.choose(root.models[root.selectedIndex], "switch")
      }
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
              Label { text: "LLAMA LOCAL"; font.bold: true; font.pixelSize: Style.font.body + 3 }
              Label { text: root.snapshot.online ? (root.snapshot.router ? "Connected · router" : "Connected · single model") : "Server offline"; color: root.snapshot.online ? Color.accent : root.muted }
            }
            Button { text: "↻"; tooltipText: "Refresh (r)"; enabled: !poll.running; onClicked: root.refresh() }
          }
          Label { width: parent.width; text: root.snapshot.endpoint || root.endpoint; color: root.muted; elide: Text.ElideMiddle }
          Label { width: parent.width; visible: text !== ""; text: root.problem || root.snapshot.error || ""; color: Color.urgent; wrapMode: Text.Wrap }
          Label { width: parent.width; visible: text !== ""; text: root.notice; wrapMode: Text.Wrap }
          Rule {}
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
          Label { text: "MODELS"; color: root.muted }
          Label { width: parent.width; visible: !root.models.length; text: "No models found. Start llama-server or check the endpoint in widget settings."; wrapMode: Text.Wrap }
          Repeater {
            id: modelRows
            model: root.models
            delegate: Rectangle {
              id: modelRow
              required property var modelData
              required property int index
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
                    text: modelRow.modelData.failed ? "Failed to load" : modelRow.modelData.state
                    color: modelRow.modelData.state === "loaded" ? Color.accent : root.muted
                  }
                  Button {
                    visible: !!root.snapshot.router && modelRow.modelData.state === "loaded"
                    text: "Unload"; enabled: !operation.running
                    onClicked: { root.selectedIndex = modelRow.index; root.choose(modelRow.modelData, "unload") }
                  }
                  Button {
                    visible: !!root.snapshot.router && modelRow.modelData.state !== "loaded"
                    text: "Load"; enabled: !operation.running && ["unloaded", "sleeping"].indexOf(modelRow.modelData.state) >= 0
                    onClicked: { root.selectedIndex = modelRow.index; root.choose(modelRow.modelData, "switch") }
                  }
                }
              }
            }
          }
          Label { width: parent.width; visible: !!root.snapshot.online && !root.snapshot.router; text: "Switching requires router mode (--models-preset or --models-dir)."; color: root.muted; wrapMode: Text.Wrap }
          Column {
            width: parent.width
            visible: root.pendingModel !== ""
            spacing: Style.space(8)
            Label {
              width: parent.width
              text: (root.pendingAction === "switch" ? "Load " : "Unload ") + root.pendingModel + "? " + (root.pendingAction === "switch" ? "The router may evict another model to free memory. Clients still choose their own model ID." : "This frees the model's memory.")
              wrapMode: Text.Wrap
            }
            Row {
              spacing: Style.space(8)
              Button { text: "Confirm"; bordered: true; enabled: !operation.running; onClicked: root.execute() }
              Button { text: "Cancel"; onClicked: root.pendingModel = "" }
            }
          }
          Repeater {
            model: root.activeModels
            delegate: Column {
              id: stats
              required property var modelData
              readonly property var metrics: modelData.metrics || ({})
              width: content.width
              spacing: Style.space(8)
              Rule {}
              Label { width: parent.width; text: modelData.id + " · USAGE"; elide: Text.ElideMiddle; color: root.muted }
              Stat { label: "Prompt tokens processed"; value: root.amount(stats.metrics.prompt_tokens_total) }
              Stat { label: "Prompt tokens cached"; value: root.amount(stats.metrics.prompt_tokens_cached_total) }
              Stat { label: "Output tokens"; value: root.amount(stats.metrics.tokens_predicted_total) }
              Stat { label: "Generation throughput"; value: root.amount(stats.metrics.predicted_tokens_seconds, " tok/s", 1) }
              Repeater {
                model: stats.modelData.slots || []
                delegate: Column {
                  required property var modelData
                  width: stats.width
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
                model: stats.modelData.notes || []
                delegate: Label { required property string modelData; width: stats.width; text: modelData; color: root.muted; wrapMode: Text.Wrap }
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
          Label { width: parent.width; text: "↑↓ select · Enter load · x unload · r refresh · Esc close"; color: root.muted; wrapMode: Text.Wrap }
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
