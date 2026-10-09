import QtQuick
import Quickshell
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

  // Disk: one entry per distinct filesystem ("/" and, if separate, "/home").
  property var disks: []
  property bool scanning: false
  property bool showCandidates: false
  property bool scanned: false
  property var cacheItems: []
  property var largeItems: []

  readonly property real memUsed: Math.max(0, memTotal - memAvailable)
  readonly property real usedFraction: memTotal > 0 ? memUsed / memTotal : 0
  readonly property int usedPercent: Math.round(usedFraction * 100)
  readonly property real swapUsed: Math.max(0, swapTotal - swapFree)
  readonly property string helperPath: String(Qt.resolvedUrl("clear-ram")).replace(/^file:\/\//, "")
  readonly property string scanPath: String(Qt.resolvedUrl("scan-disk")).replace(/^file:\/\//, "")
  readonly property string homeDir: Quickshell.env("HOME") || ""

  // Switch to the theme's urgent color at 90%.
  readonly property color usageColor: {
    if (!root.bar) return Color.foreground
    if (usedFraction >= 0.9) return root.bar.urgent
    return root.bar.foreground
  }

  function gb(kb) {
    return (kb / 1024 / 1024).toFixed(1) + " GB"
  }

  // 1536 -> "1.5 KB", up to TB. Input in bytes.
  function bytesLabel(bytes) {
    var units = ["B", "KB", "MB", "GB", "TB"]
    var value = Number(bytes) || 0
    var i = 0
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i++ }
    return (i === 0 || value >= 100 ? Math.round(value) : value.toFixed(1)) + " " + units[i]
  }

  function tildePath(path) {
    if (homeDir && (path === homeDir || path.indexOf(homeDir + "/") === 0)) return "~" + path.substring(homeDir.length)
    return path
  }

  // Output of `df -B1 --output=source,size,used,avail,target`. Mounts that share
  // a source with an earlier one (e.g. /home on the same partition) are skipped.
  function parseDisks(raw) {
    var lines = String(raw || "").split("\n").slice(1)
    var seen = {}
    var result = []
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(.+)$/)
      if (!m || seen[m[1]]) continue
      seen[m[1]] = true
      var size = parseFloat(m[2])
      var used = parseFloat(m[3])
      result.push({ mount: m[5], size: size, used: used, avail: parseFloat(m[4]),
        fraction: size > 0 ? Math.min(1, used / size) : 0 })
    }
    disks = result
  }

  // Lines of `category<TAB>bytes<TAB>path` from scan-disk.
  function parseScan(raw) {
    var cache = []
    var large = []
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var parts = lines[i].split("\t")
      if (parts.length < 3) continue
      var path = parts.slice(2).join("\t")
      var item = { bytes: parseFloat(parts[1]), path: path, label: tildePath(path),
        dir: parts[0] === "large" ? (path.replace(/\/[^\/]*$/, "") || "/") : path }
      if (parts[0] === "cache") cache.push(item)
      else if (parts[0] === "large") large.push(item)
    }
    cache.sort(function(a, b) { return b.bytes - a.bytes })
    large.sort(function(a, b) { return b.bytes - a.bytes })
    cacheItems = cache
    largeItems = large
    scanned = true
    scanning = false
  }

  function scanDisk() {
    if (scanning) return
    scanning = true
    scanProc.running = true
  }

  function toggleCandidates() {
    showCandidates = !showCandidates
    if (showCandidates && !scanned) scanDisk()
  }

  // Open a terminal in `dir`. Passed as argv (no shell string), so spaces and
  // metacharacters in paths are safe.
  function openInTerminal(dir) {
    Util.execArgv(["setsid", "uwsm-app", "--", "xdg-terminal-exec", "--dir=" + dir])
    close()
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

  function refreshDisk() {
    if (!diskProc.running) diskProc.running = true
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

  Component.onCompleted: { refresh(); refreshDisk() }
  onOpenedChanged: if (opened) { status = ""; refresh(); refreshDisk() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: memProc
    command: ["cat", "/proc/meminfo"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseMeminfo(text) }
  }

  Process {
    id: diskProc
    command: ["df", "-B1", "--output=source,size,used,avail,target", "/", "/home"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseDisks(text) }
  }

  Process {
    id: scanProc
    command: [root.scanPath]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parseScan(text) }
    onExited: root.scanning = false
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

  Timer { interval: 60000; running: true; repeat: true; onTriggered: root.refreshDisk() }

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

        // ---------- Disk ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          PanelSectionHeader {
            text: "DISK"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: root.disks
            Column {
              required property var modelData
              width: parent.width
              spacing: Style.spacing.labelGap

              Item {
                width: parent.width
                implicitHeight: diskTitle.implicitHeight

                InfoValue {
                  id: diskTitle
                  text: modelData.mount
                  anchors.left: parent.left
                }
                InfoValue {
                  text: root.bytesLabel(modelData.used) + " of " + root.bytesLabel(modelData.size) + " · " + Math.round(modelData.fraction * 100) + "%"
                  color: modelData.fraction >= 0.9 ? root.bar.urgent : root.bar.foreground
                  anchors.right: parent.right
                }
              }

              Item {
                width: parent.width
                implicitHeight: Style.space(8)

                Rectangle {
                  id: diskTrack
                  anchors.fill: parent
                  radius: height / 2
                  color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
                }

                Rectangle {
                  anchors.left: diskTrack.left
                  anchors.verticalCenter: diskTrack.verticalCenter
                  height: diskTrack.height
                  radius: diskTrack.radius
                  color: modelData.fraction >= 0.9 ? root.bar.urgent : root.bar.foreground
                  width: Math.max(diskTrack.height, diskTrack.width * modelData.fraction)

                  Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }
              }

              InfoLabel {
                text: "Free " + root.bytesLabel(modelData.avail)
              }
            }
          }

          Button {
            width: parent.width
            iconText: "󰋊"
            iconSize: Style.font.body
            text: root.scanning ? "Scanning…" : (root.showCandidates ? "Hide cleanup candidates" : "Show cleanup candidates")
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            tooltipText: "Find caches and large files that could be cleaned up (read-only)"
            onClicked: root.toggleCandidates()
          }

          Column {
            visible: root.showCandidates && !root.scanning && root.scanned
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "CACHE / TEMP"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }
            InfoLabel { visible: root.cacheItems.length === 0; text: "Nothing found" }
            Repeater {
              model: root.cacheItems
              CandidateRow {}
            }

            PanelSectionHeader {
              text: "LARGE FILES"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }
            InfoLabel { visible: root.largeItems.length === 0; text: "No files over 500 MB" }
            Repeater {
              model: root.largeItems
              CandidateRow {}
            }

            Button {
              width: parent.width
              iconText: "󰑐"
              iconSize: Style.font.body
              text: "Rescan"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              tooltipText: "Run the scan again"
              onClicked: root.scanDisk()
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

  // One cleanup candidate: size + path; click opens its directory in a terminal.
  component CandidateRow: Item {
    required property var modelData

    width: parent.width
    implicitHeight: Math.max(rowPath.implicitHeight, rowSize.implicitHeight) + Style.space(6)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(4)
      color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.1)
      visible: rowMouse.containsMouse
    }

    InfoValue {
      id: rowSize
      text: root.bytesLabel(modelData.bytes)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(60)
    }

    InfoLabel {
      id: rowPath
      text: modelData.label
      elide: Text.ElideMiddle
      anchors.left: rowSize.right
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openInTerminal(modelData.dir)
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
