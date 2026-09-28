import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// RAM usage pill for the bar. Left click opens a popup with a usage breakdown
// and a "Clear RAM" button that syncs, drops the page cache, and compacts
// memory via the root helper next to this file (run through pkexec).
Panel {
  id: root
  moduleName: "pdnhan.ram"
  ipcTarget: "pdnhan.ram"

  // Values in kB, straight from /proc/meminfo.
  property real memTotal: 0
  property real memAvailable: 0
  property real cached: 0
  property real buffers: 0
  property real swapTotal: 0
  property real swapFree: 0

  property bool clearing: false
  property string status: ""
  property real availableBeforeClear: 0

  // Models currently loaded by the local ollama server (from /api/ps).
  property var ollamaModels: []
  property bool ollamaReachable: false
  property string unloadingModel: ""

  readonly property real memUsed: Math.max(0, memTotal - memAvailable)
  readonly property real usedFraction: memTotal > 0 ? memUsed / memTotal : 0
  readonly property int usedPercent: Math.round(usedFraction * 100)
  readonly property real swapUsed: Math.max(0, swapTotal - swapFree)
  readonly property string helperPath: String(Qt.resolvedUrl("clear-ram")).replace(/^file:\/\//, "")

  // Switch to the theme's urgent color at 90%.
  readonly property color usageColor: {
    if (!root.bar) return Color.foreground
    if (usedFraction >= 0.9) return root.bar.urgent
    return root.bar.foreground
  }

  function gb(kb) {
    return (kb / 1024 / 1024).toFixed(1) + " GB"
  }

  function parseMeminfo(raw) {
    var values = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^(\w+):\s+(\d+)/)
      if (match) values[match[1]] = parseFloat(match[2])
    }
    if (!values.MemTotal) return
    memTotal = values.MemTotal
    memAvailable = values.MemAvailable || 0
    cached = values.Cached || 0
    buffers = values.Buffers || 0
    swapTotal = values.SwapTotal || 0
    swapFree = values.SwapFree || 0

    if (availableBeforeClear > 0) {
      var freed = memAvailable - availableBeforeClear
      status = freed > 0 ? "Freed " + gb(freed) : "Caches dropped"
      availableBeforeClear = 0
    }
  }

  function refresh() {
    if (!memProc.running) memProc.running = true
    if (opened && !ollamaProc.running) ollamaProc.running = true
  }

  function parseOllama(raw) {
    try {
      var models = JSON.parse(raw).models || []
      ollamaModels = models
      ollamaReachable = true
    } catch (e) {
      ollamaModels = []
      ollamaReachable = false
    }
  }

  // "29m left", "45s left", or "pinned" for keep_alive=-1 (ollama reports a
  // far-future expiry for those).
  function expiryLabel(expiresAt) {
    // JS Date can't parse nanosecond fractions; keep milliseconds.
    var when = Date.parse(String(expiresAt).replace(/(\.\d{3})\d+/, "$1"))
    if (!isFinite(when)) return ""
    var seconds = Math.round((when - Date.now()) / 1000)
    if (seconds > 365 * 24 * 3600) return "pinned"
    if (seconds <= 0) return "unloading"
    if (seconds < 60) return seconds + "s left"
    return Math.round(seconds / 60) + "m left"
  }

  // Same as `ollama stop <model>`: a keep_alive of 0 evicts it immediately.
  function unloadModel(name) {
    if (unloadProc.running) return
    unloadingModel = name
    unloadProc.command = ["curl", "-s", "--max-time", "10", "http://127.0.0.1:11434/api/generate",
      "-d", JSON.stringify({ model: name, keep_alive: 0 })]
    unloadProc.running = true
  }

  function clearRam() {
    if (clearing) return
    clearing = true
    status = "Clearing…"
    availableBeforeClear = memAvailable
    clearProc.running = true
  }

  Component.onCompleted: refresh()
  onOpenedChanged: if (opened) { status = ""; refresh() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: memProc
    command: ["cat", "/proc/meminfo"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseMeminfo(text) }
  }

  Process {
    id: ollamaProc
    command: ["curl", "-s", "--max-time", "1", "http://127.0.0.1:11434/api/ps"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseOllama(text) }
  }

  Process {
    id: unloadProc
    onExited: {
      root.unloadingModel = ""
      root.refresh()
    }
  }

  Process {
    id: clearProc
    command: ["pkexec", root.helperPath]
    onExited: function(exitCode) {
      root.clearing = false
      if (exitCode === 0) {
        root.refresh()
      } else {
        root.availableBeforeClear = 0
        root.status = exitCode === 126 || exitCode === 127 ? "Authorization cancelled" : "Clear failed"
      }
    }
  }

  Timer { interval: root.opened ? 1000 : 3000; running: true; repeat: true; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: vertical ? "󰍛" : "󰍛 " + root.usedPercent + "%"
    slotSize: Style.bar.iconSlot * (vertical ? 1 : 2)
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.bar.run("omarchy-launch-or-focus-tui btop")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.clearRam()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            text: "󰍛"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Memory"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: (root.status || (root.gb(root.memUsed) + " of " + root.gb(root.memTotal))).toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.usedPercent + "%"
            color: root.usageColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Usage bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.usageColor
            width: Math.max(barTrack.height, barTrack.width * root.usedFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
          }
        }

        // ---------- Stats ----------
        Row {
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Used"; value: root.gb(root.memUsed) }
            InfoPair { label: "Available"; value: root.gb(root.memAvailable) }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Cache"; value: root.gb(root.cached + root.buffers) }
            InfoPair { label: "Swap"; value: root.swapTotal > 0 ? root.gb(root.swapUsed) : "—" }
          }
        }

        // ---------- Ollama loaded models ----------
        PanelSeparator {
          visible: root.ollamaReachable
          foreground: root.bar.foreground
        }

        Column {
          visible: root.ollamaReachable
          width: parent.width
          spacing: Style.spacing.labelGap

          PanelSectionHeader {
            text: "OLLAMA"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          InfoLabel {
            visible: root.ollamaModels.length === 0
            text: "No model loaded"
          }

          Repeater {
            model: root.ollamaModels
            Item {
              required property var modelData
              readonly property bool unloading: root.unloadingModel === modelData.name

              width: parent.width
              implicitHeight: Math.max(modelInfo.implicitHeight, unloadButton.implicitHeight)

              Column {
                id: modelInfo
                anchors.left: parent.left
                anchors.right: unloadButton.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                InfoValue {
                  text: String(modelData.name).replace(/:latest$/, "")
                  elide: Text.ElideRight
                  width: parent.width
                }
                InfoLabel {
                  text: root.gb(modelData.size / 1024) + " · " + (unloading ? "unloading" : root.expiryLabel(modelData.expires_at))
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              Button {
                id: unloadButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅙"
                iconSize: Style.font.body
                text: unloading ? "Unloading…" : "Unload"
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                tooltipText: "Free this model's memory now (ollama stop)"
                onClicked: root.unloadModel(modelData.name)
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Button {
          width: parent.width
          iconText: "󰃢"
          iconSize: Style.font.title
          text: root.clearing ? "Clearing…" : "Clear RAM"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          bordered: true
          hasCursor: true
          tooltipText: "Sync, drop page cache, and compact memory (asks for your password)"
          onClicked: root.clearRam()
        }
      }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
