import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "rohirik.oma-server"

  property bool isHomelabMode: false
  property string currentMode: "HOST_LAPTOP"
  property string statusSummary: "Laptop Mode"

  function checkStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  function toggleMode() {
    if (root.bar) {
      if (isHomelabMode) {
        root.bar.run("oma-server disable")
      } else {
        root.bar.run("omarchy-launch-floating-terminal-with-presentation oma-server enable")
      }
    }
  }

  function runDiff() {
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation oma-server diff")
    }
  }

  function runRescue() {
    if (root.bar) {
      root.bar.run("omarchy-launch-floating-terminal-with-presentation oma-server rescue")
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: statusProc
    command: ["oma-server", "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        var out = text.trim()
        if (out.indexOf("HOMELAB_MODE") !== -1) {
          root.isHomelabMode = true
          root.currentMode = "HOMELAB_MODE"
          root.statusSummary = "Homelab Mode (Active)"
        } else {
          root.isHomelabMode = false
          root.currentMode = "HOST_LAPTOP"
          root.statusSummary = "Laptop Mode"
        }
      }
    }
  }

  Timer {
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.checkStatus()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.isHomelabMode ? "⚡" : "💻"
    active: root.isHomelabMode
    tooltipText: "Oma Server: " + root.statusSummary + "\nLeft-click: Toggle mode\nRight-click: Actions menu"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        contextMenu.popup()
      } else {
        root.toggleMode()
      }
    }
  }

  Menu {
    id: contextMenu
    title: "Oma Server"

    MenuItem {
      text: root.isHomelabMode ? "💻 Switch to Laptop Mode" : "⚡ Switch to Homelab Mode"
      onTriggered: root.toggleMode()
    }

    MenuItem {
      text: "🔍 Preview Transition Diff"
      onTriggered: root.runDiff()
    }

    MenuSeparator {}

    MenuItem {
      text: "🚨 Emergency Reset (Rescue)"
      onTriggered: root.runRescue()
    }
  }
}
