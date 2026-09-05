import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Port of the waybar custom/poll-rate module. The value (seconds) now governs
// how often the script-driven bar widgets (tla.vpn) re-run their scripts.
// Click opens the same picker menu, rendered by the shell via the walker shim.
BarWidget {
  id: root
  moduleName: "tla.poll-rate"

  property string value: ""

  function refresh() {
    if (!valueProc.running) valueProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "tla.poll-rate"
    function refresh(): void { root.broadcast("refresh") }
  }

  Process {
    id: valueProc
    command: ["bash", "-lc", "\"$HOME/.config/waybar/poll-rate.sh\" value"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: { root.value = text.trim() }
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓅 " + root.value
    fontSize: Style.font.caption
    tooltipText: "Poll rate in seconds of script-driven bar widgets"
    onPressed: function() {
      if (root.bar) root.bar.run("\"$HOME/.config/waybar/poll-rate-menu.sh\"")
    }
  }
}
