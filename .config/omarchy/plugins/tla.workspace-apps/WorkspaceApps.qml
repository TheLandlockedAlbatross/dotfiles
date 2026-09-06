import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Picker for the per-workspace default program (Super+Middle-click on the
// desktop). A clipboard-manager lookalike: same surface tokens, card size,
// search header, list on the left and detail pane on the right.
//
// Summoned by ~/.config/hypr/scripts/workspace-app.sh with a payload of
// {workspace, monitor, rows, commandsFile, currentKey, selectionFile, doneFile}. The
// answer {action: "set"|"test", row} goes to selectionFile and doneFile is
// touched, exactly like omarchy.menu's select mode; closing without a choice
// touches doneFile alone.
//
//   Enter        set as the workspace default and launch
//   Shift+Enter  test: launch without setting
//   Delete       forget the row (never the current default)
//   typing       fuzzy-filters; the typed text leads as a "Run" row and
//                executables on PATH join the matches below the history
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property string scriptPath: Quickshell.env("HOME") + "/.config/hypr/scripts/workspace-app.sh"

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property var rows: []
  property var commands: []
  property string commandsFile: ""
  property int commandLimit: 40
  property int workspace: 0
  property string monitor: ""
  property string currentKey: ""
  property string selectionFile: ""
  property string doneFile: ""
  property bool requestActive: false

  // Shares the [menu] surface tokens — themes that style the menu (and the
  // clipboard) style this picker too.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(875), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.rows = Array.isArray(payload.rows) ? payload.rows : []
    root.commands = []
    root.commandsFile = String(payload.commandsFile || "")
    if (root.commandsFile) commandsView.reload()
    root.workspace = Number(payload.workspace || 0)
    root.monitor = String(payload.monitor || "")
    root.currentKey = String(payload.currentKey || "")
    root.selectionFile = String(payload.selectionFile || "")
    root.doneFile = String(payload.doneFile || "")
    root.requestActive = !!root.doneFile

    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
    if (root.shell && root.shell.appLibrary) root.shell.appLibrary.refreshIcons()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Host-driven close (hide/toggle) counts as a cancel.
  function close() {
    root.finish(null)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // Hand the answer back to the script. Selection first, then the done
  // marker, in one shell so the order holds.
  function finish(selection) {
    root.opened = false
    if (!root.requestActive || !root.doneFile) return

    var activeSelectionFile = root.selectionFile
    var activeDoneFile = root.doneFile
    root.requestActive = false
    root.selectionFile = ""
    root.doneFile = ""

    if (selection === null || selection === undefined) {
      resultProc.command = ["bash", "-c", ": > " + Util.shellQuote(activeDoneFile)]
    } else {
      resultProc.command = ["bash", "-c", "printf '%s\\n' " + Util.shellQuote(JSON.stringify(selection))
        + " > " + Util.shellQuote(activeSelectionFile) + "; : > " + Util.shellQuote(activeDoneFile)]
    }
    resultProc.running = true
  }

  // 0 = prefix, 1 = substring, 2 = subsequence, -1 = no match.
  function fuzzyScore(text, needle) {
    if (!needle) return 0
    var hay = String(text || "").toLowerCase()
    if (hay.indexOf(needle) === 0) return 0
    if (hay.indexOf(needle) !== -1) return 1
    var at = 0
    for (var i = 0; i < needle.length; i++) {
      at = hay.indexOf(needle.charAt(i), at)
      if (at === -1) return -1
      at += 1
    }
    return 2
  }

  function rowScore(row, needle) {
    if (!needle) return 0
    var best = -1
    var fields = [row.label, row.subtext, row.id]
    for (var i = 0; i < fields.length; i++) {
      var score = root.fuzzyScore(fields[i], needle)
      if (score !== -1 && (best === -1 || score < best)) best = score
    }
    return best
  }

  function rankedMatches(list, needle, scoreOf) {
    var hits = []
    for (var i = 0; i < list.length; i++) {
      var score = scoreOf(list[i], needle)
      if (score !== -1) hits.push({ item: list[i], score: score, order: i })
    }
    hits.sort(function(a, b) { return a.score - b.score || a.order - b.order })
    return hits.map(function(h) { return h.item })
  }

  function rebuildDisplay() {
    var raw = root.filterText.trim()
    var needle = raw.toLowerCase()

    displayModel.clear()

    // Whatever was typed leads, ready to run as a command.
    if (raw.length > 0) {
      displayModel.append(root.displayRow({
        key: "command:" + raw,
        kind: "command",
        id: "",
        label: "Run “" + raw + "”",
        subtext: raw,
        exec: raw,
        icon: root.iconForProgram(root.programOf(raw)),
        file: "",
        section: "custom",
        lastUsed: 0,
        uses: 0,
        defaultFor: []
      }, true))
    }

    // The workspace's own history: everything at rest, fuzzy-ranked once typing.
    var history = root.rankedMatches(root.rows, needle, root.rowScore)
    var seen = ({})
    for (var i = 0; i < history.length; i++) {
      var row = history[i]
      if (row.kind === "command" && String(row.exec || "") === raw) continue
      seen[String(row.exec || "")] = true
      displayModel.append(root.displayRow(row, false))
    }

    // Executables on PATH only join once something is typed.
    if (raw.length > 0) {
      var found = root.rankedMatches(root.commands, needle, function(cmd, n) {
        return root.fuzzyScore(cmd.name, n)
      })
      var added = 0
      for (var j = 0; j < found.length && added < root.commandLimit; j++) {
        var name = String(found[j].name || "")
        if (name === raw || seen[name]) continue
        displayModel.append(root.displayRow({
          key: "command:" + name,
          kind: "command",
          id: "",
          label: name,
          subtext: String(found[j].dir || "") + "/" + name,
          exec: name,
          icon: String(found[j].icon || ""),
          file: "",
          section: "path",
          lastUsed: 0,
          uses: 0,
          defaultFor: []
        }, false))
        added += 1
      }
    }

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function displayRow(row, synthetic) {
    return {
      key: String(row.key || ""),
      kind: String(row.kind || ""),
      appId: String(row.id || ""),
      label: String(row.label || ""),
      subtext: String(row.subtext || ""),
      exec: String(row.exec || ""),
      icon: String(row.icon || ""),
      file: String(row.file || ""),
      section: String(row.section || ""),
      lastUsed: Number(row.lastUsed || 0),
      uses: Number(row.uses || 0),
      defaultFor: Array.isArray(row.defaultFor) ? row.defaultFor.join(", ") : "",
      synthetic: synthetic === true,
      isCurrent: !!root.currentKey && String(row.key || "") === root.currentKey
    }
  }

  function entryFor(row) {
    var entry = { kind: row.kind, label: row.label, exec: row.exec }
    if (row.kind === "desktop") {
      entry.id = row.appId
      entry.icon = row.icon
      entry.file = row.file
    }
    return entry
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function activateIndex(index, action) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.finish({ action: action, row: root.entryFor(row) })
  }

  function forgetIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    if (row.synthetic || row.isCurrent || row.section === "path") return

    Util.execArgv([root.scriptPath, "forget", row.key])

    var next = []
    for (var i = 0; i < root.rows.length; i++) {
      if (String(root.rows[i].key || "") !== row.key) next.push(root.rows[i])
    }
    root.rows = next

    if (displayModel.count <= 1) {
      root.selectedIndex = 0
      root.cursorActive = false
    } else if (root.selectedIndex >= displayModel.count - 1) {
      root.selectedIndex = displayModel.count - 2
    }

    root.disarmPointer()
    root.rebuildDisplay()
  }

  // Commands without a desktop entry of their own get the theme's terminal icon.
  readonly property string commandIcon: "utilities-terminal"

  function iconSource(icon) {
    if (!root.shell || !root.shell.appLibrary) return ""
    return root.shell.appLibrary.iconSource(icon || root.commandIcon)
  }

  // The program a typed command line runs, past env/launcher wrappers.
  function programOf(commandLine) {
    var words = String(commandLine || "").split(" ")
    for (var i = 0; i < words.length; i++) {
      var w = words[i]
      if (!w || w === "env" || w === "uwsm-app" || w === "setsid" || w === "--" || /^[A-Za-z_][A-Za-z0-9_]*=/.test(w)) continue
      return w.slice(w.lastIndexOf("/") + 1)
    }
    return ""
  }

  function iconForProgram(name) {
    if (!name) return ""
    for (var i = 0; i < root.commands.length; i++) {
      if (root.commands[i].name === name) return String(root.commands[i].icon || "")
    }
    return ""
  }

  function formatWhen(epoch) {
    if (!epoch) return "never"
    return new Date(epoch * 1000).toLocaleString(Qt.locale(), "ddd d MMM HH:mm")
  }

  function sectionLabel(row) {
    if (row.synthetic) return "Typed command"
    if (row.isCurrent) return "Current default for workspace " + root.workspace
    if (row.section === "previous") return "Earlier default for workspace " + root.workspace
    if (row.section === "path") return "Executable on PATH"
    return "Recently launched"
  }

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Process {
    id: resultProc
  }

  // The PATH index the script writes before summoning: too big for the
  // summon argv, so it arrives by file.
  FileView {
    id: commandsView
    path: root.commandsFile
    printErrors: false
    onLoaded: {
      try { root.commands = JSON.parse(text()) } catch (e) { root.commands = [] }
      if (root.opened && root.filterText) root.rebuildDisplay()
    }
    onLoadFailed: root.commands = []
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-workspace-apps"
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

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            root.forgetIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(displayModel.count - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive && (event.modifiers & Qt.ShiftModifier)) root.activateIndex(root.selectedIndex, "test")
            else if (root.cursorActive) root.activateIndex(root.selectedIndex, "set")
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || ("Default for workspace " + root.workspace + "…")
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          Row {
            anchors.fill: parent
            spacing: 0

            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: displayModel
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: row
                  required property int index
                  required property string kind
                  required property string label
                  required property string subtext
                  required property string icon
                  required property bool isCurrent
                  required property bool synthetic
                  required property string section

                  readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: hasCursor ? root.selectedBackground : "transparent"

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    anchors.topMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(8)
                    spacing: Style.space(10)

                    Item {
                      width: parent.height
                      height: parent.height

                      Image {
                        id: appIcon
                        anchors.centerIn: parent
                        width: Style.font.iconLarge
                        height: Style.font.iconLarge
                        fillMode: Image.PreserveAspectFit
                        sourceSize.width: width * Screen.devicePixelRatio
                        sourceSize.height: height * Screen.devicePixelRatio
                        source: root.iconSource(row.icon)
                        asynchronous: true
                        visible: status === Image.Ready
                      }

                      Text {
                        anchors.centerIn: parent
                        visible: !appIcon.visible
                        text: row.synthetic ? "" : (row.section === "path" ? "" : (row.kind === "command" ? "" : "󰘔"))
                        color: row.hasCursor ? root.selectedText : root.foreground
                        opacity: 0.72
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.iconLarge
                      }
                    }

                    Column {
                      width: parent.width - parent.height - parent.spacing - (row.isCurrent ? markText.width + parent.spacing : 0)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(2)

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: row.label
                        color: row.hasCursor ? root.selectedText : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                      }

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        visible: row.subtext.length > 0 && row.subtext !== row.label
                        text: row.subtext
                        color: row.hasCursor ? root.selectedText : root.foreground
                        opacity: 0.6
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        wrapMode: Text.NoWrap
                      }
                    }

                    Text {
                      id: markText
                      visible: row.isCurrent
                      anchors.verticalCenter: parent.verticalCenter
                      text: "✓"
                      color: row.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    onPositionChanged: function(mouse) {
                      root.selectFromPointer(row.index, row, mouse)
                    }
                    onClicked: function(mouse) {
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      var test = (mouse.button === Qt.MiddleButton) || (mouse.modifiers & Qt.ShiftModifier)
                      root.activateIndex(row.index, test ? "test" : "set")
                    }
                  }
                }
              }
            }

            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              property var activeRow: displayModel.count > 0 && root.selectedIndex >= 0 && root.selectedIndex < displayModel.count ? displayModel.get(root.selectedIndex) : null

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.28)
              }

              Column {
                id: detail
                visible: parent.activeRow !== null
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                spacing: Style.space(10)

                property var row: parent.activeRow

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: detail.row ? detail.row.label : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  wrapMode: Text.WrapAnywhere
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: detail.row ? root.sectionLabel(detail.row) : ""
                  color: root.selectedText
                  opacity: 0.9
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: detail.row ? [
                    { k: "Command", v: detail.row.exec },
                    { k: "Desktop entry", v: detail.row.kind === "desktop" ? detail.row.file : "" },
                    { k: "Last launched", v: detail.row.synthetic || detail.row.section === "path" ? "" : root.formatWhen(detail.row.lastUsed) },
                    { k: "Launched via picker", v: detail.row.synthetic || detail.row.section === "path" ? "" : String(detail.row.uses) + (detail.row.uses === 1 ? " time" : " times") },
                    { k: "Default on workspaces", v: detail.row.defaultFor }
                  ] : []

                  delegate: Column {
                    required property var modelData
                    width: detail.width
                    visible: String(modelData.v || "").length > 0
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: parent.modelData.k
                      color: root.foreground
                      opacity: 0.55
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: String(parent.modelData.v || "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      wrapMode: Text.WrapAnywhere
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: root.contentMargin
                text: "Enter  set + launch    Shift+Enter  test only    Del  forget"
                color: root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              text: "󰀻"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: "Nothing launched yet. Type a command to run it."
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
