import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "WorkspaceModel.js" as Model

// Clone of omarchy.workspaces adapted for the 40-workspace decade-per-monitor
// layout: each bar lists only the workspaces bound to its own monitor, shows
// the position digit within the decade (11-20 -> 1..0), and highlights the
// focused workspace with the theme accent color instead of the 󱓻 block glyph
// (the ethereal-extended "no active icon" convention from the waybar days).
//
// Borrowed workspaces: workspace-map.sh gives every display a decade for good
// (slot table in ~/.local/state/hypr/workspace-map-slots). When a display is
// unplugged its decade moves to a survivor; those workspaces are drawn in the
// theme's urgent (red) color with their full number, an accent underline when
// focused, and a tooltip saying whose they are and why they are here.
BarWidget {
  id: root
  moduleName: "tla.workspaces"

  readonly property string screenName:
    (QsWindow.window && QsWindow.window.screen) ? QsWindow.window.screen.name : ""

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/hypr"
  property var slots: ({})
  property string mode: "decade"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  FileView {
    path: root.stateDir + "/workspace-map-slots"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.slots = Model.parseSlots(text())
    onLoadFailed: root.slots = ({})
  }

  FileView {
    path: root.stateDir + "/workspace-map-mode"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.mode = Model.parseMode(text())
    onLoadFailed: root.mode = "decade"
  }

  // Monitor descriptions come from lastIpcObject, which Quickshell fills only
  // after a monitors query; ask for one at start and whenever displays change.
  Component.onCompleted: Hyprland.refreshMonitors()
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name.indexOf("monitor") === 0) Hyprland.refreshMonitors()
    }
  }

  function monitorDescription(monitor) {
    return monitor && monitor.lastIpcObject && monitor.lastIpcObject.description
      ? String(monitor.lastIpcObject.description) : ""
  }

  readonly property var connectedDescriptions: {
    var list = []
    var values = Hyprland.monitors.values
    for (var i = 0; i < values.length; i++) {
      var d = monitorDescription(values[i])
      if (d) list.push(d)
    }
    return list
  }

  function monitorWorkspaceIds() {
    var ids = []
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var ws = values[i]
      if (ws.id > 0 && ws.monitor && ws.monitor.name === root.screenName) ids.push(ws.id)
    }
    ids.sort(function(a, b) { return a - b })
    return ids
  }

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }
    return null
  }

  function placementOf(workspace) {
    if (!workspace) return { displaced: false, owner: "", ownerConnected: false }
    return Model.placement(workspace.id, monitorDescription(workspace.monitor), root.slots, root.mode,
                           root.connectedDescriptions)
  }

  function tooltipFor(id, place) {
    if (!place.displaced) return strings.t("tooltip.workspace").arg(id)
    var owner = place.owner || strings.t("tooltip.unknownDisplay")
    return place.ownerConnected
      ? strings.t("tooltip.borrowedMoved").arg(id).arg(owner)
      : strings.t("tooltip.borrowedDisconnected").arg(id).arg(owner)
  }

  function focusWorkspace(id) {
    if (root.bar) root.bar.run("hyprctl dispatch workspace " + id)
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : Math.max(1, root.monitorWorkspaceIds().length)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.monitorWorkspaceIds()

      WidgetButton {
        id: button
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
        readonly property var place: root.placementOf(workspace)
        readonly property bool displaced: place.displaced

        bar: root.bar
        text: Model.label(modelData, displaced)
        active: focused
        useActiveColor: true
        activeColor: displaced ? Color.urgent : Color.accent
        foreground: displaced ? Color.urgent : (root.bar ? root.bar.barForeground : Color.foreground)
        tooltipText: root.tooltipFor(modelData, place)
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }

        // Red already says "borrowed", so focus on a borrowed workspace is
        // marked with a short accent underline instead of the accent text.
        Rectangle {
          visible: button.displaced && button.focused
          width: Math.round(button.width * 0.4)
          height: Math.max(2, Math.round(Style.spaceReal(0.5)))
          radius: height / 2
          color: Color.accent
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Math.round(button.height * 0.14)
        }
      }
    }
  }
}
