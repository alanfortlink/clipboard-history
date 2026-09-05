import QtQuick
import qs.Commons
import qs.Ui
import "Classify.js" as Classify

// Right-hand preview pane for the clipboard picker.
// Renders a full preview plus metadata chips, per derived type.
// `result` is a Fuzzy search result: { row: {entry, content, app, type, ...}, positions }
Item {
  id: root

  property var result: null
  property var entry: result ? result.row.entry : null
  property string derived: result ? result.row.type : ""
  // Wired by the picker: opens the current result (browser for links).
  property var onOpen: function() {}

  readonly property string font_: Style.font.menuFamily
  readonly property color fg: Color.menu.text
  readonly property color mutedFg: Util.alpha(fg, 0.55)
  readonly property color chipBg: Util.alpha(fg, 0.07)
  readonly property color lineColor: Util.alpha(fg, 0.16)

  property string bodyText: ""

  onResultChanged: prepare()

  function prepare() {
    bodyText = ""
    if (!entry) return
    var t = derived
    if (t === "json") {
      var pretty = Classify.prettyJson(String(entry.text || ""), 200000)
      bodyText = pretty || String(entry.text || "")
    } else if (t === "html") {
      bodyText = Classify.stripHtml(String(entry.text || "")) || String(entry.text || "")
    } else if (t === "text" || t === "code" || t === "email" || t === "number") {
      bodyText = String(entry.text || "")
    }
  }

  function rawSafe() {
    return entry ? String(entry.text || "").trim() : ""
  }

  function rgbLine() {
    var rgb = Classify.colorToRgb(rawSafe())
    return rgb ? "rgb(" + rgb[0] + ", " + rgb[1] + ", " + rgb[2] + ")" : ""
  }

  function hslLine() {
    var hsl = Classify.colorToHsl(rawSafe())
    return hsl ? "hsl(" + hsl[0] + ", " + hsl[1] + "%, " + hsl[2] + "%)" : ""
  }

  // URL inside the decoded QR payload ("" when the payload is not a link).
  function qrUrl() {
    if (!entry || !entry.qr) return ""
    var url = Classify.extractUrl(entry.qr)
    if (url) return url
    var trimmed = String(entry.qr).trim()
    return root.bareDomainRe.test(trimmed) ? trimmed : ""
  }

  readonly property var bareDomainRe: /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}(?:\/[^\s]*)?$/i

  function metaChips() {
    if (!result) return []
    var r = result.row
    var e = r.entry
    var chips = []
    if (r.app) chips.push(Classify.prettyApp(r.app))
    if (e.qr) chips.push("QR: " + Classify.firstLine(e.qr, 40))
    if (e.type === "text" && e.text) {
      var st = Classify.textStats(e.text)
      chips.push(Classify.plural(st.words, "word"))
      chips.push(Classify.plural(st.lines, "line"))
    }
    if (r.bytes > 0) chips.push(Classify.formatBytes(r.bytes))
    if (e.type === "image" && e.w && e.h) chips.push(e.w + "×" + e.h)
    if (e.type === "image") chips.push(e.mime || "image")
    if (e.pinned) chips.push("★ pinned")
    if (r.uses > 0) chips.push("pasted " + r.uses + "×")
    return chips
  }

  // ------------------------------------------------------------- header

  Row {
    id: headerRow
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(10)

    Rectangle {
      width: Style.space(38)
      height: width
      radius: Style.cornerRadius
      color: root.chipBg
      anchors.verticalCenter: parent.verticalCenter

      Text {
        anchors.centerIn: parent
        text: Classify.typeIcon(root.derived)
        color: root.fg
        font.family: root.font_
        font.pixelSize: Style.font.heading
      }
    }

    Column {
      width: parent.width - Style.space(48) - badge.width - Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: {
          if (!root.entry) return ""
          var e = root.entry
          if (e.type === "image") return e.qr ? Classify.firstLine(e.qr, 120) : Classify.fileBase(e.path)
          if (e.type === "files") {
            var base = Classify.fileBase(e.paths[0])
            return e.paths.length > 1 ? base + "  +" + (e.paths.length - 1) + " more" : base
          }
          return Classify.firstLine(e.text, 200)
        }
        color: root.fg
        font.family: root.font_
        font.pixelSize: Style.font.title
        font.bold: true
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 1
      }

      Text {
        width: parent.width
        text: {
          if (!root.result) return ""
          var r = root.result.row
          var parts = []
          if (r.ts) parts.push(Classify.formatFullDate(r.ts))
          if (r.bytes) parts.push(Classify.formatBytes(r.bytes))
          return parts.join("  ·  ")
        }
        color: root.mutedFg
        font.family: root.font_
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        maximumLineCount: 1
      }
    }

    Rectangle {
      id: badge
      anchors.verticalCenter: parent.verticalCenter
      radius: height / 2
      color: root.chipBg
      width: badgeLabel.implicitWidth + Style.space(14)
      height: Style.space(20)

      Text {
        id: badgeLabel
        anchors.centerIn: parent
        text: Classify.typeIcon(root.derived) + " " + Classify.typeLabel(root.derived)
        color: root.mutedFg
        font.family: root.font_
        font.pixelSize: Style.font.caption
      }
    }
  }

  Rectangle {
    id: divider
    anchors.top: headerRow.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.space(10)
    height: Style.normalBorderWidth
    color: root.lineColor
  }

  // ------------------------------------------------------------- body

  // text-ish body (text / code / json / html / email / number)
  Flickable {
    id: textBody
    anchors.top: divider.bottom
    anchors.bottom: metaRow.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.space(10)
    anchors.bottomMargin: Style.space(10)
    visible: root.bodyText !== ""
    clip: true
    contentWidth: width
    contentHeight: bodyEdit.implicitHeight
    boundsBehavior: Flickable.StopAtBounds

    WheelHandler {
      acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
      onWheel: function(ev) {
        if (ev.angleDelta.y < 0) textBody.flick(0, -240)
        else textBody.flick(0, 240)
        ev.accepted = true
      }
    }

    TextEdit {
      id: bodyEdit
      width: parent.width
      readOnly: true
      activeFocusOnPress: false
      text: root.bodyText
      textFormat: TextEdit.PlainText
      color: root.fg
      font.family: root.font_
      font.pixelSize: Style.font.body
      wrapMode: TextEdit.Wrap
      selectionColor: Util.alpha(Color.accent, 0.4)
    }
  }

  // color body
  Column {
    anchors.top: divider.bottom
    anchors.bottom: metaRow.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.space(10)
    anchors.bottomMargin: Style.space(10)
    visible: root.derived === "color"
    spacing: Style.space(14)

    Rectangle {
      width: Math.min(Style.space(240), parent.width)
      height: Style.space(120)
      radius: Style.cornerRadius
      color: root.hexRe.test(root.rawSafe()) ? root.rawSafe() : "transparent"
      border.width: Style.normalBorderWidth
      border.color: root.lineColor
    }

    Text {
      text: root.rawSafe()
      color: root.fg
      font.family: root.font_
      font.pixelSize: Style.font.heading
      font.bold: true
    }

    Text {
      visible: root.rgbLine().length > 0
      text: root.rgbLine()
      color: root.mutedFg
      font.family: root.font_
      font.pixelSize: Style.font.body
    }

    Text {
      visible: root.hslLine().length > 0
      text: root.hslLine()
      color: root.mutedFg
      font.family: root.font_
      font.pixelSize: Style.font.body
    }
  }

  // link body
  Column {
    anchors.top: divider.bottom
    anchors.bottom: metaRow.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.space(10)
    anchors.bottomMargin: Style.space(10)
    visible: root.derived === "link"
    spacing: Style.space(10)

    Text {
      text: Classify.urlDomain(root.entry ? String(root.entry.text || "") : "")
      color: Color.accent
      font.family: root.font_
      font.pixelSize: Style.font.display
      font.bold: true
      elide: Text.ElideRight
      width: parent.width
      maximumLineCount: 1
    }

    Text {
      text: root.entry ? Classify.firstLine(String(root.entry.text || ""), 400) : ""
      color: root.fg
      font.family: root.font_
      font.pixelSize: Style.font.body
      wrapMode: Text.WrapAnywhere
      width: parent.width
    }

    Text {
      text: "Ctrl+O opens this link in your browser"
      color: root.mutedFg
      font.family: root.font_
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      radius: height / 2
      color: Util.alpha(Color.accent, 0.15)
      width: linkOpenLabel.implicitWidth + Style.space(16)
      height: Style.space(22)

      Row {
        anchors.centerIn: parent
        spacing: Style.space(4)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "󰌹"
          color: Color.accent
          font.family: root.font_
          font.pixelSize: Style.font.caption
        }

        Text {
          id: linkOpenLabel
          anchors.verticalCenter: parent.verticalCenter
          text: "Open link"
          color: Color.accent
          font.family: root.font_
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.onOpen()
      }
    }
  }

  // image body
  Column {
    anchors.top: divider.bottom
    anchors.bottom: metaRow.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.space(10)
    anchors.bottomMargin: Style.space(10)
    visible: root.derived === "image"
    spacing: Style.space(8)

    // Decoded QR payload sits above the image so it is immediately readable.
    Rectangle {
      visible: root.entry && root.entry.qr
      width: parent.width
      height: qrContent.height + Style.space(12)
      radius: Style.cornerRadius
      color: root.chipBg

      Column {
        id: qrContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(6)
        anchors.topMargin: Style.space(6)
        anchors.leftMargin: Style.space(6)
        anchors.rightMargin: Style.space(6)
        spacing: Style.space(4)

        Row {
          spacing: Style.space(6)

          Text {
            text: "󰐲"
            color: Color.accent
            font.family: root.font_
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: "QR code content"
            color: Color.accent
            font.family: root.font_
            font.pixelSize: Style.font.caption
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        TextEdit {
          id: qrValue
          width: parent.width
          readOnly: true
          activeFocusOnPress: false
          text: root.entry && root.entry.qr ? root.entry.qr : ""
          textFormat: TextEdit.PlainText
          color: root.fg
          font.family: root.font_
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: TextEdit.WrapAnywhere
          selectionColor: Util.alpha(Color.accent, 0.4)
        }

        // QR payloads frequently encode links — offer the open affordance.
        Rectangle {
          visible: root.qrUrl().length > 0
          radius: height / 2
          color: Util.alpha(Color.accent, 0.15)
          width: qrOpenLabel.implicitWidth + Style.space(16)
          height: Style.space(20)

          Row {
            anchors.centerIn: parent
            spacing: Style.space(4)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰌹"
              color: Color.accent
              font.family: root.font_
              font.pixelSize: Style.font.caption
            }

            Text {
              id: qrOpenLabel
              anchors.verticalCenter: parent.verticalCenter
              text: "Open link"
              color: Color.accent
              font.family: root.font_
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.onOpen()
          }
        }
      }
    }

    Item {
      width: parent.width
      height: Math.max(0, parent.height
             - (root.entry && root.entry.qr ? qrContent.height + Style.space(12) + Style.space(8) : 0)
             - infoLabel.height - Style.space(12))

      Image {
        id: img
        anchors.centerIn: parent
        width: parent.width
        height: parent.height
        source: root.entry && root.entry.path ? Util.fileUrl(root.entry.path) : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        cache: false
      }

      Rectangle {
        anchors.fill: img
        color: "transparent"
        border.width: Style.normalBorderWidth
        border.color: root.lineColor
        radius: Style.space(4)
        visible: img.status === Image.Ready
      }

      Text {
        anchors.centerIn: parent
        visible: img.status === Image.Error || img.status === Image.Null
        text: "Preview unavailable"
        color: root.mutedFg
        font.family: root.font_
        font.pixelSize: Style.font.body
      }
    }

    Text {
      id: infoLabel
      text: {
        if (!root.entry) return ""
        var e = root.entry
        var dims = e.w && e.h ? e.w + " × " + e.h + " px  ·  " : ""
        return dims + (e.mime || "image") + (e.bytes ? "  ·  " + Classify.formatBytes(e.bytes) : "")
      }
      color: root.mutedFg
      font.family: root.font_
      font.pixelSize: Style.font.caption
    }
  }

  // files body
  Column {
    anchors.top: divider.bottom
    anchors.bottom: metaRow.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.space(10)
    anchors.bottomMargin: Style.space(10)
    visible: root.derived === "files"
    spacing: Style.space(6)
    clip: true

    Repeater {
      model: {
        if (!root.entry || root.entry.type !== "files") return []
        return (root.entry.paths || []).slice(0, 10)
      }

      delegate: Row {
        required property var modelData
        width: parent ? parent.width : 0
        spacing: Style.space(8)

        Text {
          text: "󰈚"
          color: Color.accent
          font.family: root.font_
          font.pixelSize: Style.font.body
        }

        Text {
          text: Classify.fileBase(modelData)
          color: root.fg
          font.family: root.font_
          font.pixelSize: Style.font.body
          elide: Text.ElideMiddle
          width: parent.width - Style.space(24)
          maximumLineCount: 1
        }
      }
    }

    Text {
      visible: root.entry && root.entry.paths && root.entry.paths.length > 10
      text: root.entry && root.entry.paths ? "… and " + (root.entry.paths.length - 10) + " more" : ""
      color: root.mutedFg
      font.family: root.font_
      font.pixelSize: Style.font.caption
    }

    Text {
      text: root.entry && root.entry.paths && root.entry.paths.length > 0
            ? "in " + Classify.fileDir(root.entry.paths[0])
            : ""
      color: root.mutedFg
      font.family: root.font_
      font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
      width: parent.width
      maximumLineCount: 1
    }
  }

  // ------------------------------------------------------------- meta chips

  Row {
    id: metaRow
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(6)

    Rectangle {
      width: Style.space(20)
      height: Style.space(20)
      radius: height / 2
      color: root.chipBg
      anchors.verticalCenter: parent.verticalCenter

      Text {
        anchors.centerIn: parent
        text: Classify.typeIcon(root.derived)
        color: root.mutedFg
        font.family: root.font_
        font.pixelSize: Style.font.caption
      }
    }

    Rectangle {
      radius: height / 2
      color: root.chipBg
      width: typeChipText.implicitWidth + Style.space(14)
      height: Style.space(20)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        id: typeChipText
        anchors.centerIn: parent
        text: Classify.typeLabel(root.derived)
        color: root.mutedFg
        font.family: root.font_
        font.pixelSize: Style.font.caption
      }
    }

    Repeater {
      model: root.metaChips()

      delegate: Rectangle {
        required property var modelData
        property string chipText: String(modelData)

        radius: height / 2
        color: root.chipBg
        width: chipLabel.implicitWidth + Style.space(14)
        height: Style.space(20)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: chipLabel
          anchors.centerIn: parent
          text: parent.chipText
          textFormat: Text.PlainText
          color: root.mutedFg
          font.family: root.font_
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  readonly property var hexRe: /^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i
}
