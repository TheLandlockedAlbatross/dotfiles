import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Port of the waybar custom/screen-temperature module for the omarchy 4 shell
// bar. Reads hyprsunset's current temperature, shows "<icon> <T>K" tinted on a
// warm/cool gradient, and drives the same ~/.config/waybar/cycle-temperature.sh
// helper the keybinds and old bar used (single source of stepping/wrap logic).
//   scroll up/down = ±10K fine    left = -500K    right = +500K    middle = display off
BarWidget {
  id: root
  moduleName: "tla.screen-temperature"

  property int temp: 0
  readonly property bool has: temp > 0
  readonly property string icon: temp >= 5000 ? "\u{F10C3}" : "\u{F050F}"  // 󱃃 cool / 󰔏 warm

  // Warm/cool tint, ported verbatim from the waybar awk gradient: deviation
  // from 5000K, sqrt-shaped so the first steps shift color hard then taper.
  function tint(t) {
    t = Math.max(0, Math.min(10000, t))
    var d = (t - 5000) / 5000
    var r, g, b
    if (d < 0) { var s = Math.sqrt(-d); r = 255; g = Math.round(255 - s * 120); b = Math.round(255 - s * 150) }
    else       { var s2 = Math.sqrt(d); r = Math.round(255 - s2 * 150); g = Math.round(255 - s2 * 120); b = 255 }
    r = Math.max(100, r); g = Math.max(100, g); b = Math.max(100, b)
    function h(n) { return ("0" + n.toString(16)).slice(-2) }
    return "#" + h(r) + h(g) + h(b)
  }

  function refresh() { if (!tempProc.running) tempProc.running = true }
  function cycle(step) {
    if (root.bar) root.bar.run("\"$HOME/.config/waybar/cycle-temperature.sh\" " + step)
    Qt.callLater(root.refresh)
  }

  visible: has
  implicitWidth: has ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "tla.screen-temperature"
    function refresh(): void { root.broadcast("refresh") }
  }

  Process {
    id: tempProc
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = parseInt(String(text).trim(), 10)
        root.temp = isNaN(t) ? 0 : t
      }
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon + " " + root.temp + "K"
    foreground: root.tint(root.temp)
    fontSize: Style.bar.iconFont
    tooltipText: "Screen temperature: " + root.temp + "K\nscroll ±10  ·  click ∓500  ·  middle: display off"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.cycle(500)
      else if (mouseButton === Qt.MiddleButton) {
        if (root.bar) root.bar.run("\"$HOME/.config/waybar/screen-display-toggle.sh\"")
      } else root.cycle(-500)
    }
  }

  // WidgetButton has no wheel handler; overlay one for the fine ±10 steps.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    onWheel: function(wheel) { root.cycle(wheel.angleDelta.y > 0 ? 10 : -10) }
  }
}
