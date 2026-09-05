import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Port of the waybar custom/network module: reuses network-vpn.sh verbatim
// (it emits {"text","tooltip","class"}); pango <span> coloring is stripped
// and replaced with the same state colors applied natively. Refresh cadence
// follows the poll-rate widget's state file.
BarWidget {
  id: root
  moduleName: "tla.vpn"

  property string icon: ""
  property string tip: ""
  property string stateClass: ""
  property int pollMs: 1000

  function refresh() {
    if (!statusProc.running) statusProc.running = true
    if (!rateProc.running) rateProc.running = true
  }

  visible: icon !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "tla.vpn"
    function refresh(): void { root.broadcast("refresh") }
  }

  Process {
    id: statusProc
    command: ["bash", "-lc", "\"$HOME/.config/waybar/network-vpn.sh\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.icon = String(data.text || "").replace(/<[^>]*>/g, "")
          root.tip = String(data.tooltip || "")
          root.stateClass = String(data["class"] || "")
        } catch (e) {}
      }
    }
  }

  Process {
    id: rateProc
    command: ["bash", "-lc", "\"$HOME/.config/waybar/poll-rate.sh\" value"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = parseFloat(text)
        if (!isNaN(v) && v > 0) root.pollMs = Math.max(100, Math.round(v * 1000))
      }
    }
  }

  Timer {
    interval: root.pollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    tooltipText: root.tip
    active: root.stateClass !== ""
    useActiveColor: true
    activeColor: root.stateClass === "vpn-connected" ? "#88bb88"
               : root.stateClass === "vpn-tunnel" ? "#e8912d"
               : "#bb5555"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.bar) root.bar.run("\"$HOME/.config/waybar/network-vpn-incognito.sh\"")
      } else if (mouseButton === Qt.RightButton) {
        if (root.bar) root.bar.run("\"$HOME/.config/waybar/network-vpn-action.sh\" toggle")
      } else {
        if (root.bar) root.bar.run("omarchy-shell shell toggle omarchy.network")
      }
    }
  }

  // Wheel-only overlay: scroll cycles VPN relay like the waybar module did.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    onWheel: function(wheel) {
      var dir = wheel.angleDelta.y > 0 ? "next" : "prev"
      if (root.bar) root.bar.run("\"$HOME/.config/waybar/network-vpn-action.sh\" " + dir)
    }
  }
}
