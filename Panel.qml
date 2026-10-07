pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// The timeline popup. bin/what-changed does the reading (pacman.log, config
// mtimes, plugin reflogs) and hands back one JSON list, newest first; this
// file groups it by day and filters it. The script runs on open, never on a
// timer.
Panel {
  id: root
  moduleName: "nejcc.what-changed"
  ipcTarget: "nejcc.what-changed"

  property var anchorItem: null
  // The bar identifies the open panel by the widget in its slot, so the
  // popout owner is BarWidget.qml, not this nested panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string helper: String(Qt.resolvedUrl("bin/what-changed")).replace(/^file:\/\//, "")
  readonly property int days: Math.max(1, Math.min(90, parseInt(setting("days", 7), 10) || 7))

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.4)

  property var entries: []
  property bool loading: false
  property string error: ""
  property string filter: "all"
  property var expanded: ({})

  readonly property var filters: [
    { value: "all", label: "All" },
    { value: "package", label: "Packages" },
    { value: "config", label: "Config" },
    { value: "plugin", label: "Plugins" }
  ]
  readonly property var rows: buildRows(entries, filter)

  function refresh() {
    if (listProc.running) return
    root.loading = true
    root.error = ""
    listProc.running = true
  }

  function finish(text) {
    root.loading = false
    try {
      var parsed = JSON.parse(text)
      root.entries = Array.isArray(parsed) ? parsed : []
    } catch (e) {
      root.entries = []
      root.error = "Could not read the timeline"
    }
  }

  // Omarchy updates sit under Plugins: both are "the desktop itself changed".
  function matches(entry, f) {
    if (f === "all") return true
    if (f === "plugin") return entry.kind === "plugin" || entry.kind === "omarchy"
    return entry.kind === f
  }

  function dayLabel(date) {
    var today = new Date()
    var start = new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime()
    var t = date.getTime()
    if (t >= start) return "TODAY"
    if (t >= start - 86400000) return "YESTERDAY"
    return Qt.formatDate(date, "dddd d MMMM").toUpperCase()
  }

  function buildRows(list, f) {
    var out = []
    var lastDay = ""
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      if (!matches(e, f)) continue
      var date = new Date(e.ts * 1000)
      var day = dayLabel(date)
      if (day !== lastDay) {
        out.push({ header: day })
        lastDay = day
      }
      out.push({ header: "", entry: e, key: e.kind + ":" + e.ts + ":" + i, time: Qt.formatTime(date, "HH:mm") })
    }
    return out
  }

  function kindIcon(kind) {
    if (kind === "package") return "󰏗"
    if (kind === "config") return "󰒓"
    if (kind === "omarchy") return "󰚰"
    return "󰐱"
  }

  function summaryOf(e) {
    return e.command ? e.command + "  ·  " + e.summary : e.summary
  }

  function detailLines(e) {
    var lines = []
    var marks = { upgraded: "↑", downgraded: "↓", installed: "+", removed: "−", reinstalled: "↻" }
    var items = e.items || []
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      var ver = it.from ? it.from + " → " + it.to : it.to
      lines.push((marks[it.op] || "·") + "  " + it.name + "  " + ver)
    }
    var detail = e.detail || []
    for (var j = 0; j < detail.length; j++) if (detail[j]) lines.push(detail[j])
    return lines
  }

  function activate(row) {
    var e = row.entry
    if (e.path) {
      Util.execArgv(["omarchy-launch-editor", e.path])
      root.close()
      return
    }
    if (detailLines(e).length === 0) return
    var next = Object.assign({}, root.expanded)
    if (next[row.key]) delete next[row.key]
    else next[row.key] = true
    root.expanded = next
  }

  function stepFilter(delta) {
    var i = 0
    for (; i < filters.length; i++) if (filters[i].value === root.filter) break
    root.filter = filters[(i + delta + filters.length) % filters.length].value
  }

  onOpenedChanged: if (opened) refresh()

  Process {
    id: listProc
    command: ["bash", root.helper, "--days", String(root.days), "--json"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.finish(text) }
    onExited: function(code) { if (code !== 0) { root.loading = false; root.error = "what-changed exited with " + code } }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.stepFilter(dx) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰋚"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "What changed"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              width: parent.width
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              text: (root.loading ? "Reading…" : "Last " + root.days + (root.days === 1 ? " day" : " days")).toUpperCase()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              width: parent.width
              elide: Text.ElideRight
            }
          }
        }

        ButtonGroup {
          options: root.filters
          value: root.filter
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          focusable: false
          onChanged: function(v) { root.filter = v }
        }

        PanelSeparator { width: column.width; foreground: root.fg }

        Text {
          visible: text !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.error !== "" ? root.error
            : (!root.loading && root.rows.length === 0 ? "Nothing changed in this window." : "")
          color: root.error !== "" ? Color.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Flickable {
          id: flick
          width: parent.width
          height: Math.min(list.implicitHeight, Style.space(520))
          contentWidth: width
          contentHeight: list.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: list
            width: flick.width
            spacing: Style.space(2)

            Repeater {
              model: root.rows

              Column {
                id: rowItem
                required property var modelData
                readonly property bool isHeader: modelData.header !== ""
                readonly property var lines: isHeader ? [] : root.detailLines(modelData.entry)
                readonly property bool isOpen: !isHeader && root.expanded[modelData.key] === true
                readonly property bool clickable: !isHeader && (!!modelData.entry.path || lines.length > 0)

                width: list.width
                spacing: Style.space(2)

                Text {
                  visible: rowItem.isHeader
                  topPadding: Style.space(8)
                  bottomPadding: Style.space(2)
                  textFormat: Text.PlainText
                  text: rowItem.modelData.header
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                }

                Rectangle {
                  visible: !rowItem.isHeader
                  width: parent.width
                  height: Math.max(kindText.implicitHeight, summaryText.implicitHeight) + Style.space(8)
                  radius: Style.space(4)
                  color: hover.containsMouse && rowItem.clickable ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08) : "transparent"

                  Text {
                    id: kindText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    textFormat: Text.PlainText
                    text: rowItem.isHeader ? "" : root.kindIcon(rowItem.modelData.entry.kind)
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    id: timeText
                    anchors.left: kindText.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(48)
                    textFormat: Text.PlainText
                    text: rowItem.isHeader ? "" : rowItem.modelData.time
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    id: summaryText
                    anchors.left: timeText.right
                    anchors.right: chevron.left
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: rowItem.isHeader ? "" : root.summaryOf(rowItem.modelData.entry)
                    color: !rowItem.isHeader && rowItem.modelData.entry.status && rowItem.modelData.entry.status !== "completed" ? Color.urgent : root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideMiddle
                  }

                  Text {
                    id: chevron
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: rowItem.lines.length > 0 ? (rowItem.isOpen ? "󰅀" : "󰅂") : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: rowItem.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.activate(rowItem.modelData)
                  }
                }

                Repeater {
                  model: rowItem.isOpen ? rowItem.lines : []

                  Text {
                    required property string modelData
                    x: Style.space(74)
                    width: rowItem.width - x
                    textFormat: Text.PlainText
                    text: modelData
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
