import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Shared.js" as Shared

// Checkmk problems in the bar: an icon that turns into a count when a host
// or service is not OK, a popup listing them worst first, and a desktop
// notification when something new breaks.
//
// All network work goes through bin/omarmk-fetch, which reads the automation
// secret from its file and gives it to curl on stdin. The secret never enters
// this QML scene, which every other shell plugin can traverse.
Panel {
  id: root
  moduleName: "io.github.comm4nd0.omarmk"
  // The shell routes `omarchy-shell shell toggle <id>` to bar widgets
  // itself; a handler here would be registered once per monitor's bar.
  manageIpc: false

  // ---------------------------------------------------------------- settings
  readonly property string siteUrl: Model.normalizeSiteUrl(setting("siteUrl", ""))
  readonly property string username: String(setting("username", "omarmk")).trim()
  readonly property string secretPath: Model.expandHome(setting("secretFile", "~/.config/omarmk/secret"), Quickshell.env("HOME"))
  readonly property int refreshIntervalSec: Math.max(15, Number(setting("refreshIntervalSec", 60)) || 60)
  readonly property bool notify: setting("notify", true) === true
  readonly property int notifyMinSeverity: Model.minSeverityFor(String(setting("notifyMinState", "warning")))
  readonly property bool notifyRecoveries: setting("notifyRecoveries", false) === true
  readonly property bool hideHandled: setting("hideHandled", true) === true
  readonly property bool onlyHardStates: setting("onlyHardStates", true) === true
  readonly property bool includeHosts: setting("includeHosts", true) === true
  readonly property bool allowInsecureTls: setting("allowInsecureTls", false) === true

  readonly property bool configured: root.siteUrl !== "" && root.username !== ""

  // ------------------------------------------------------------------- state
  property var rows: []
  property var error: null
  property bool loaded: false
  property real lastUpdated: 0
  property real nowSec: Date.now() / 1000
  // key -> severity from the last successful poll; null until the first one,
  // so start-up produces one summary instead of a popup per problem.
  property var notifiedState: null
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var visibleRows: Model.visibleRows(root.rows, {
    hideHandled: root.hideHandled, onlyHard: root.onlyHardStates, includeHosts: root.includeHosts
  })
  readonly property int hiddenCount: Model.visibleRows(root.rows, { includeHosts: root.includeHosts }).length - root.visibleRows.length
  readonly property int worst: Model.worstSeverity(root.visibleRows)
  readonly property int problemCount: root.visibleRows.length

  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("bin/omarmk-fetch"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }

  readonly property color warnColor: Qt.tint(root.barForeground, Qt.rgba(0.95, 0.68, 0.2, 0.8))
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color dimText: Qt.darker(root.barForeground, 1.45)

  function colorFor(sev) {
    if (sev >= 3) return Color.urgent
    if (sev === 2) return Color.accent
    if (sev === 1) return root.warnColor
    return root.barForeground
  }

  readonly property string barGlyph: {
    if (!root.configured) return Model.GLYPH.setup
    if (root.error) return Model.GLYPH.offline
    if (root.worst >= 3) return Model.GLYPH.crit
    if (root.worst > 0) return Model.GLYPH.warn
    return Model.GLYPH.ok
  }

  readonly property string statusText: {
    if (!root.configured) return "OmarMK needs a Checkmk site URL"
    if (root.error) return root.error.text
    if (!root.loaded) return "Checking…"
    return Model.summary(root.visibleRows)
  }

  // ------------------------------------------------------------------ fetching
  function refresh() {
    if (!root.configured || fetchProc.running) return
    fetchProc.command = ["bash", root.helperPath, root.username, root.secretPath,
      root.allowInsecureTls ? "1" : "0",
      Model.servicesUrl(root.siteUrl),
      root.includeHosts ? Model.hostsUrl(root.siteUrl) : ""]
    fetchProc.running = true
  }

  function handleResponse(text) {
    var result = Model.parseResponse(text)
    root.nowSec = Date.now() / 1000
    if (result.error) {
      // Keep the last good list visible under the error, and say so once
      // per outage rather than on every poll.
      if (!root.error && root.notify && root.loaded)
        sendNotification({ urgency: "normal", title: "OmarMK: Checkmk unreachable", body: result.error.text })
      root.error = result.error
      return
    }
    root.error = null
    root.rows = result.rows
    root.loaded = true
    root.lastUpdated = root.nowSec
    root.selectedIndex = Math.min(root.selectedIndex, Math.max(0, root.visibleRows.length - 1))

    var decided = Model.notifications(root.notifiedState, root.visibleRows, {
      minSeverity: root.notifyMinSeverity, notifyRecoveries: root.notifyRecoveries
    })
    root.notifiedState = decided.state
    if (root.notify) for (var i = 0; i < decided.notes.length; i++) sendNotification(decided.notes[i])
  }

  function sendNotification(note) {
    // Instances on other monitors reach the same decision within one poll.
    var key = note.urgency + "\n" + note.title + "\n" + (note.body || "")
    if (!Shared.claim(key, Date.now(), root.refreshIntervalSec * 1000 + 15000)) return
    var argv = ["notify-send", "--app-name=OmarMK", "--urgency=" + note.urgency,
      "--icon=" + (note.urgency === "low" ? "dialog-information" : "dialog-warning"), note.title]
    if (note.body) argv.push(note.body)
    Quickshell.execDetached(argv)
  }

  function updatedText() {
    var a = Model.age(root.lastUpdated, root.nowSec)
    return a === "" || /^\d+s$/.test(a) ? "Updated just now" : "Updated " + a + " ago"
  }

  function openInBrowser(row) {
    var url = Model.guiUrl(root.siteUrl, row)
    if (url !== "") Quickshell.execDetached(["xdg-open", url])
  }

  // Re-check immediately when the target changes, and start the
  // notification baseline over: a different site is a different world.
  onSiteUrlChanged: { root.rows = []; root.loaded = false; root.error = null; root.notifiedState = null; Qt.callLater(refresh) }
  onUsernameChanged: Qt.callLater(refresh)
  onIncludeHostsChanged: Qt.callLater(refresh)

  Process {
    id: fetchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleResponse(String(text || ""))
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.configured
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Ages in the list tick while the popup is open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  onOpenedChanged: {
    if (!opened) return
    root.nowSec = Date.now() / 1000
    root.cursorActive = false
    root.refresh()
  }

  // ------------------------------------------------------------------ bar icon
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property bool showCount: root.configured && !root.error && root.problemCount > 0 && !vertical
    text: showCount ? root.problemCount + " " + root.barGlyph : root.barGlyph
    slotSize: Style.bar.iconSlot * (showCount ? 2 : 1)
    active: root.configured && !root.error && root.worst >= 3
    dimmed: !root.configured || (root.loaded && !root.error && root.problemCount === 0)
    tooltipText: root.statusText
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.refresh()
      else if (mouseButton === Qt.RightButton) root.openInBrowser(null)
      else root.toggle()
    }
  }

  // --------------------------------------------------------------------- popup
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (dy === 0 || root.visibleRows.length === 0) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.selectedIndex = Math.max(0, Math.min(root.visibleRows.length - 1, root.selectedIndex + dy))
        list.positionViewAtIndex(root.selectedIndex, ListView.Contain)
      }
      onActivateRequested: {
        if (root.cursorActive && root.visibleRows[root.selectedIndex]) root.openInBrowser(root.visibleRows[root.selectedIndex])
        else root.openInBrowser(null)
      }
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (key) {
        if (key === "r") root.refresh()
        else if (key === "o") root.openInBrowser(null)
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        // Header: state glyph, summary, actions.
        Item {
          width: parent.width
          height: Math.max(headerText.implicitHeight, Style.space(30))

          Text {
            id: headerGlyph
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: root.barGlyph
            color: root.error ? Color.urgent : root.colorFor(root.worst)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
          }

          Column {
            id: headerText
            anchors.left: headerGlyph.right
            anchors.leftMargin: Style.space(10)
            anchors.right: actions.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Checkmk"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.statusText
              color: root.error ? Color.urgent : root.dimText
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }

          Row {
            id: actions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: [
                { glyph: Model.GLYPH.refresh, tip: "refresh", act: "refresh" },
                { glyph: Model.GLYPH.open, tip: "open", act: "open" }
              ]
              delegate: Rectangle {
                required property var modelData
                width: Style.space(28)
                height: Style.space(28)
                radius: Style.cornerRadius
                color: actionArea.containsMouse ? root.hoverFill : "transparent"
                visible: root.configured
                opacity: modelData.act === "refresh" && fetchProc.running ? 0.4 : 1

                Text {
                  anchors.centerIn: parent
                  text: modelData.glyph
                  color: root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                MouseArea {
                  id: actionArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: modelData.act === "refresh" ? root.refresh() : root.openInBrowser(null)
                }
              }
            }
          }
        }

        // Setup hint until the site URL is set.
        Text {
          visible: !root.configured
          width: parent.width
          leftPadding: Style.space(6)
          rightPadding: Style.space(6)
          textFormat: Text.PlainText
          wrapMode: Text.Wrap
          color: root.dimText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          text: "Set the site URL (for example http://checkmk.lan/mysite) and an automation "
            + "username in this widget's settings, and put the user's secret in "
            + root.secretPath + ". See the README for creating a read-only user."
        }

        Text {
          visible: root.configured && root.loaded && root.visibleRows.length === 0 && !root.error
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          topPadding: Style.space(8)
          bottomPadding: Style.space(8)
          textFormat: Text.PlainText
          text: "Nothing needs attention"
          color: root.dimText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        ListView {
          id: list
          width: parent.width
          visible: root.visibleRows.length > 0
          height: Math.min(contentHeight, Style.space(440))
          clip: true
          spacing: Style.space(4)
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          model: root.visibleRows

          delegate: Rectangle {
            id: rowItem
            required property var modelData
            required property int index
            readonly property bool selected: root.cursorActive && index === root.selectedIndex
            width: list.width
            height: rowContent.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: selected ? root.selectedFill : (rowArea.containsMouse ? root.hoverFill : "transparent")

            Rectangle {
              id: badge
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.top: parent.top
              anchors.topMargin: Style.space(7)
              width: Style.space(62)
              height: badgeText.implicitHeight + Style.space(4)
              radius: Math.min(4, Style.cornerRadius)
              color: Util.alpha(root.colorFor(Model.severity(rowItem.modelData)), 0.18)
              border.width: 1
              border.color: root.colorFor(Model.severity(rowItem.modelData))

              Text {
                id: badgeText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: Model.stateLabel(rowItem.modelData)
                color: root.colorFor(Model.severity(rowItem.modelData))
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Column {
              id: rowContent
              anchors.left: badge.right
              anchors.leftMargin: Style.space(10)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.top: parent.top
              anchors.topMargin: Style.space(6)
              spacing: Style.space(2)

              Item {
                width: parent.width
                height: titleText.implicitHeight

                Text {
                  id: titleText
                  anchors.left: parent.left
                  anchors.right: ageText.left
                  anchors.rightMargin: Style.space(8)
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  text: rowItem.modelData.kind === "host" ? rowItem.modelData.host : rowItem.modelData.service
                  color: root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  id: ageText
                  anchors.right: parent.right
                  anchors.baseline: titleText.baseline
                  textFormat: Text.PlainText
                  text: (rowItem.modelData.acknowledged ? "ack · " : "")
                    + (rowItem.modelData.downtime ? "downtime · " : "")
                    + (rowItem.modelData.hard ? "" : "soft · ")
                    + Model.age(rowItem.modelData.since, root.nowSec)
                  color: root.dimText
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
              Text {
                width: parent.width
                visible: rowItem.modelData.kind !== "host"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                text: rowItem.modelData.host
                color: root.dimText
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: Model.shortOutput(rowItem.modelData, 240)
                color: root.dimText
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: rowArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openInBrowser(rowItem.modelData)
            }
          }
        }

        Text {
          visible: root.configured && root.loaded
          width: parent.width
          leftPadding: Style.space(6)
          textFormat: Text.PlainText
          color: root.dimText
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          text: root.updatedText()
            + (root.hiddenCount > 0 ? " · " + root.hiddenCount + " acknowledged/soft hidden" : "")
            + (root.visibleRows.length > 0 ? " · click to open in Checkmk" : "")
        }
      }
    }
  }
}
