import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Store.js" as Store
import "Fuzzy.js" as Fuzzy
import "Classify.js" as Classify

// Clipboard history picker — Raycast-style: fuzzy search bar, result list,
// and a per-type preview pane. Clone of omarchy.clipboard with richer
// capture metadata (app, size, dims, pins, usage) and full-text fuzzy search.
Item {
  id: root

  property bool opened: false
  property string filterText: ""
  property string typeFilter: "" // chip filter, "" = all; combined into the query
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool cursorVisible: true
  property bool clearConfirmOpen: false
  property var history: []
  property var results: [] // [{ row, score, positions }]

  property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/clipboard-history-rich.json"
  property int historyLimit: 1500
  property int displayLimit: 200
  property var typeCache: ({}) // id → derived type, memoized

  // Theme surface tokens (menu) — tracks the active Omarchy theme.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color accent: Color.accent
  property color mutedFg: Util.alpha(foreground, 0.55)
  property color chipBg: Util.alpha(foreground, 0.07)
  property color lineColor: Util.alpha(foreground, 0.14)
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int headerHeight: Math.max(Style.space(40), Style.font.heading + Style.spacing.controlPaddingY * 2)
  readonly property int cardWidth: Math.min(Style.space(980), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(680), panel.height - Style.gapsOut * 2)
  readonly property int rowHeight: Style.space(52)
  readonly property int listWidth: Math.round(card.width * 0.46)

  readonly property var currentResult: results.length > 0 && selectedIndex >= 0 && selectedIndex < results.length ? results[selectedIndex] : null

  // ------------------------------------------------------------ lifecycle

  function open() {
    root.opened = true
    root.filterText = ""
    root.typeFilter = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.cancelClearHistory()
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // ------------------------------------------------------------ store

  function loadHistory(raw) {
    root.history = Store.parseHistory(raw, Math.floor(Date.now() / 1000))
    root.typeCache = {}
    if (root.opened) root.rebuild()
  }

  function saveHistory() {
    var pruned = Store.prune(root.history, root.historyLimit)
    root.history = pruned.entries
    historyFile.setText(JSON.stringify(root.history, null, 1) + "\n")
    if (pruned.droppedImagePaths.length > 0) queueGc(pruned.droppedImagePaths)
  }

  // Serialize GC batches: a single reusable Process would silently drop
  // overlapping runs, so pending paths queue until the current rm exits.
  property var gcQueue: []
  function queueGc(paths) {
    root.gcQueue.push(paths)
    if (!gcProc.running) runNextGc()
  }
  function runNextGc() {
    if (root.gcQueue.length === 0) return
    gcProc.command = ["rm", "-f"].concat(root.gcQueue.shift())
    gcProc.running = true
  }

  function addClipboardJson(line) {
    var entry = null
    try { entry = JSON.parse(String(line || "")) } catch (e) { return }
    if (!entry) return
    root.history = Store.addEntry(root.history, entry, Math.floor(Date.now() / 1000))
    root.saveHistory()
    if (root.opened) root.rebuild()
  }

  // ------------------------------------------------------------ search

  function effectiveQuery() {
    var q = root.filterText
    if (root.typeFilter === "pinned") return q + (q ? " " : "") + "is:pinned"
    if (root.typeFilter) return "type:" + root.typeFilter + (q ? " " + q : "")
    return q
  }

  function rebuild() {
    var now = Math.floor(Date.now() / 1000)
    var rows = []
    for (var i = 0; i < root.history.length; i++) {
      var entry = root.history[i]
      var derived = root.typeCache[entry.id]
      if (derived === undefined) {
        derived = Classify.deriveType(entry)
        root.typeCache[entry.id] = derived
      }
      rows.push(Store.buildRow(entry, derived, now))
    }
    root.results = Fuzzy.searchRows(rows, root.effectiveQuery(), now, root.displayLimit)

    if (root.results.length === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= root.results.length) root.selectedIndex = root.results.length - 1

    Qt.callLater(function() {
      if (root.results.length > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function setFilter(next) {
    root.filterText = next
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuild()
  }

  function setTypeFilter(next) {
    root.typeFilter = next
    root.selectedIndex = 0
    root.disarmPointer()
    root.rebuild()
  }

  // ------------------------------------------------------------ navigation

  function select(delta) {
    if (root.results.length === 0) return
    root.disarmPointer()
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = delta < 0 ? root.results.length - 1 : 0
    } else {
      root.selectedIndex = (root.selectedIndex + delta + root.results.length) % root.results.length
    }
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (root.results.length === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, root.results.length - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  // ------------------------------------------------------------ actions

  function pasteResult(result) {
    if (!result) return
    root.close()
    root.history = Store.touch(root.history, result.row.entry.id, Math.floor(Date.now() / 1000))
    root.saveHistory()
    Quickshell.execDetached([root.pluginDir + "/paste-entry.sh", result.row.entry.id])
  }

  function copyResult(result) {
    if (!result) return
    root.close()
    Quickshell.execDetached([root.pluginDir + "/paste-entry.sh", result.row.entry.id, "--copy-only"])
  }

  function openResult(result) {
    if (!result) return
    root.close()
    Quickshell.execDetached([root.pluginDir + "/open-entry.sh", result.row.entry.id])
  }

  function removeIndex(index) {
    if (index < 0 || index >= root.results.length) return
    var entry = root.results[index].row.entry
    root.history = Store.removeById(root.history, entry.id)
    delete root.typeCache[entry.id]
    root.saveHistory()
    if (root.results.length <= 1) root.selectedIndex = 0
    else if (root.selectedIndex >= root.results.length - 1) root.selectedIndex = root.results.length - 2
    root.rebuild()
  }

  function togglePinIndex(index) {
    if (index < 0 || index >= root.results.length) return
    root.history = Store.togglePin(root.history, root.results[index].row.entry.id)
    root.saveHistory()
    root.rebuild()
  }

  function requestClearHistory() {
    if (root.history.length === 0) return
    clearConfirm.selectedIndex = 1
    root.clearConfirmOpen = true
  }

  function cancelClearHistory() {
    root.clearConfirmOpen = false
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmClearHistory() {
    var dropped = []
    for (var i = 0; i < root.history.length; i++) {
      if (root.history[i].type === "image" && root.history[i].path) dropped.push(root.history[i].path)
    }
    root.history = []
    root.typeCache = {}
    root.saveHistory()
    if (dropped.length > 0) queueGc(dropped)
    root.selectedIndex = 0
    root.clearConfirmOpen = false
    root.rebuild()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Component.onCompleted: initProc.running = true

  // ------------------------------------------------------------ capture

  ListModel { id: displayModel }

  PointerMoveGate { id: pointerGate; referenceItem: card }

  FileView {
    id: historyFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadHistory(text())
    onLoadFailed: root.loadHistory("[]")
    onFileChanged: reload()
  }

  Process {
    id: gcProc
    onExited: runNextGc()
  }

  // Reap watchers left behind by a previous shell instance, then start our
  // own. pdeathsig kills them whenever the shell exits.
  Process {
    id: initProc
    command: ["pkill", "-f", "wl-paste .*--watch .*capture\\.py"]
    onExited: {
      snapshotProc.running = true
      watchProc.running = true
    }
  }

  Process {
    id: snapshotProc
    command: ["python3", root.pluginDir + "/capture.py"]
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  Process {
    id: watchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--watch", "python3", root.pluginDir + "/capture.py", "watch"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  Timer {
    id: watchRestartTimer
    interval: 1000
    repeat: false
    onTriggered: if (!watchProc.running) watchProc.running = true
  }

  // Cursor blink
  Timer {
    running: root.opened
    interval: 530
    repeat: true
    onTriggered: root.cursorVisible = !root.cursorVisible
  }

  // ------------------------------------------------------------ window

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "tank-clipboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: function() {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.clearConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.clearConfirmOpen) {
            if (clearConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else if (root.typeFilter) root.setTypeFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (event.modifiers & Qt.ShiftModifier) root.requestClearHistory()
            else root.removeIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier))) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || (event.key === Qt.Key_N && (event.modifiers & Qt.ControlModifier))) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-8)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(8)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(root.results.length - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            root.togglePinIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_O && (event.modifiers & Qt.ControlModifier)) {
            root.openResult(root.currentResult)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (event.modifiers & Qt.ShiftModifier) root.copyResult(root.currentResult)
            else if (event.modifiers & Qt.AltModifier) root.openResult(root.currentResult)
            else root.pasteResult(root.currentResult)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: clearConfirm
          anchors.fill: parent
          opened: root.clearConfirmOpen
          z: 10
          message: "Delete entire clipboard history?"
          confirmText: "Delete"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelClearHistory()
          onConfirmed: root.confirmClearHistory()
        }
      }

      // ---------------------------------------------------------- layout

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(10)

        // ---- search bar
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: searchIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰍛"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Row {
            anchors.left: searchIcon.right
            anchors.leftMargin: Style.space(10)
            anchors.right: countLabel.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              id: searchText
              width: Math.min(implicitWidth, parent.width - Style.space(6))
              text: root.filterText || "Search clipboard\u2026   (type:image  app:firefox  <2h  is:pinned)"
              color: root.foreground
              opacity: root.filterText.length > 0 ? 1 : 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
              maximumLineCount: 1
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(1, Style.space(2))
              height: Style.font.heading
              color: root.accent
              visible: root.cursorVisible && root.cursorActive
            }
          }

          Text {
            id: countLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: {
              var shown = root.results.length
              var total = root.history.length
              if (shown === total) return total + " items"
              return shown + " of " + total
            }
            color: root.mutedFg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- type chips
        Row {
          id: chipsRow
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: [
              { key: "", label: "All" },
              { key: "text", label: "󰈙 Text" },
              { key: "link", label: "󰌹 Links" },
              { key: "image", label: "󰋲 Images" },
              { key: "files", label: "󰉋 Files" },
              { key: "code", label: "󰅴 Code" },
              { key: "json", label: "󰘦 JSON" },
              { key: "color", label: "󰏘 Colors" },
              { key: "pinned", label: "★ Pinned" }
            ]

            delegate: Rectangle {
              required property var modelData
              property string chipKey: modelData.key
              property string chipLabel: modelData.label
              property bool active: root.typeFilter === chipKey

              radius: height / 2
              color: active ? Util.alpha(root.accent, 0.18) : root.chipBg
              width: chipLabel_.implicitWidth + Style.space(16)
              height: Style.space(22)

              Text {
                id: chipLabel_
                anchors.centerIn: parent
                text: modelData.label
                color: parent.active ? root.accent : root.mutedFg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setTypeFilter(parent.chipKey)
              }
            }
          }
        }

        // ---- list + preview
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - chipsRow.height - footer.height - Style.space(30)

          ListView {
            id: resultList
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: root.listWidth
            model: displayModel
            clip: true
            spacing: Style.space(3)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: row
              required property int index
              required property var row_    // results[i]: { row, score, positions }
              required property string derived
              required property string titleHtml
              required property string subtitle

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex
              readonly property var entry: row_ ? row_.row.entry : null

              width: resultList.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                // thumbnail for images, glyph tile otherwise
                Rectangle {
                  width: Style.space(36)
                  height: Style.space(36)
                  radius: Style.space(6)
                  color: root.chipBg
                  anchors.verticalCenter: parent.verticalCenter
                  clip: true

                  Image {
                    anchors.fill: parent
                    visible: row.derived === "image"
                    source: row.entry && row.entry.path ? Util.fileUrl(row.entry.path) : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    smooth: true
                    sourceSize.width: 72
                    sourceSize.height: 72
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: row.derived !== "image"
                    text: Classify.typeIcon(row.derived)
                    color: root.foreground
                    opacity: 0.85
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.iconLarge
                  }
                }

                Column {
                  width: parent.width - Style.space(46) - pinMark.width
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: row.titleHtml
                    textFormat: Text.StyledText
                    color: row.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }

                  Text {
                    width: parent.width
                    text: row.subtitle
                    color: root.mutedFg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }
                }

                Text {
                  id: pinMark
                  anchors.verticalCenter: parent.verticalCenter
                  text: "★"
                  visible: row.entry && row.entry.pinned ? true : false
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) { root.selectFromPointer(row.index, row, mouse) }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                  root.pasteResult(root.currentResult)
                }
              }
            }
          }

          // divider between list and preview
          Rectangle {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.leftMargin: root.listWidth + Style.space(6)
            width: Style.normalBorderWidth
            color: root.lineColor
          }

          PreviewPane {
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.left: parent.left
            anchors.leftMargin: root.listWidth + Style.space(14)
            result: root.currentResult
            visible: root.currentResult !== null
          }

          // empty state
          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              text: "󰅌"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              text: root.history.length === 0
                    ? "Clipboard is empty — copy something first"
                    : "No matches for “" + root.filterText + "”"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }

        // ---- footer key hints
        Row {
          id: footer
          width: parent.width
          spacing: Style.space(10)

          Repeater {
            model: [
              { keys: "ctrl+n/p", hint: "navigate" },
              { keys: "enter", hint: "paste" },
              { keys: "shift+enter", hint: "copy" },
              { keys: "ctrl+o", hint: "open" },
              { keys: "tab", hint: "pin" },
              { keys: "del", hint: "remove" },
              { keys: "esc", hint: "close" }
            ]

            delegate: Row {
              required property var modelData
              spacing: Style.space(4)

              Rectangle {
                radius: Style.space(3)
                color: root.chipBg
                width: keyText.implicitWidth + Style.space(10)
                height: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  id: keyText
                  anchors.centerIn: parent
                  text: modelData.keys
                  color: root.mutedFg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                text: modelData.hint
                color: root.mutedFg
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ display model

  // results → displayModel rows. Wrapped in function so it can be called from
  // rebuild(); title/subtitle strings precomputed here, not in delegates.
  function syncDisplayModel() {
    displayModel.clear()
    for (var i = 0; i < root.results.length; i++) {
      var r = root.results[i]
      var e = r.row.entry
      var derived = r.row.type
      var titleHtml = ""
      var subtitleParts = []

      if (e.type === "image") {
        titleHtml = "Image" + (e.mime ? " · " + e.mime.replace("image/", "").toUpperCase() : "")
        if (e.w && e.h) titleHtml += " · " + e.w + "×" + e.h
        subtitleParts.push(Classify.formatBytes(r.row.bytes))
      } else if (e.type === "files") {
        var base = Classify.fileBase(e.paths[0])
        titleHtml = Fuzzy.escapeHtml(e.paths.length > 1 ? base + "  +" + (e.paths.length - 1) + " more" : base)
        subtitleParts.push(Classify.fileDir(e.paths[0]))
      } else {
        titleHtml = Fuzzy.highlightFirstLine(e.text, r.positions, "<b><font color=\"" + root.accentHex() + "\">", "</font></b>")
        var st = Classify.textStats(e.text)
        if (st.words > 0) subtitleParts.push(Classify.plural(st.words, "word"))
      }

      subtitleParts.push(Classify.typeLabel(derived))
      if (r.row.app) subtitleParts.push(Classify.prettyApp(r.row.app))
      if (r.row.ts) subtitleParts.push(Classify.formatAge(r.row.ts, Math.floor(Date.now() / 1000)))

      displayModel.append({
        row_: r,
        derived: derived,
        titleHtml: titleHtml,
        subtitle: subtitleParts.join("  ·  ")
      })
    }
  }

  // 6-digit hex for rich-text <font color> tags, whatever toString() returns.
  function accentHex() {
    var s = root.accent.toString()
    return "#" + s.slice(-6)
  }

  onResultsChanged: syncDisplayModel()
}
