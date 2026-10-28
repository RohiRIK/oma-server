import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "rohirik.oma-server"
  ipcTarget: "rohirik.oma-server"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color okColor: Color.accent
  readonly property color warnColor: Qt.lighter(urgent, 1.25)
  readonly property color infoColor: Color.accent
  readonly property color syncColor: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color muted: Qt.darker(foreground, 2.0)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Live Telemetry State
  property bool isHomelabMode: false
  property string currentMode: "HOST_LAPTOP"
  property string sinceTime: ""
  property string elapsedHuman: "00h 00m 00s"
  property string inhibitorStatus: "Inactive"
  property string timeoutStatus: "Standby"
  property string dpmsStatus: "ON (Active)"
  property string quickshellStatus: "Running"
  property int protectedActive: 0
  property int protectedTotal: 10
  property string healthStatus: "OK"
  property bool loaded: false

  // Deep Server Mode (opt-in; set up with `oma-server deep-setup`)
  property bool deepAllowed: false
  property string deepNotice: ""

  // Interactive Controls & Async Progress State
  property string selectedTimeout: "0"
  readonly property var timeoutPresets: [
    { label: "Off", value: "0" },
    { label: "30m", value: "30m" },
    { label: "1h",  value: "1h" },
    { label: "2h",  value: "2h" },
    { label: "4h",  value: "4h" }
  ]

  property bool isTransitioning: false
  property string transitionLabel: ""
  property int transitionProgress: 0
  property int transitionElapsedMs: 0
  property int spinnerIndex: 0
  readonly property var spinnerFrames: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  readonly property string spinnerChar: spinnerFrames[spinnerIndex % spinnerFrames.length]

  property string errorNotice: ""
  property string recoveryHint: ""

  function formatElapsedTenths(ms) {
    var totalTenths = Math.max(0, Math.floor((Number(ms) || 0) / 100))
    var secs = Math.floor(totalTenths / 10)
    var tenths = totalTenths % 10
    return String(secs) + "." + String(tenths) + "s"
  }

  function refresh() {
    if (!statusProc.running) {
      statusProc.running = true
    }
  }

  function startTransition(label, cmdArray, shouldCloseOnSuccess) {
    if (isTransitioning || actionProc.running) return
    errorNotice = ""
    recoveryHint = ""
    isTransitioning = true
    transitionLabel = label
    transitionProgress = 20
    transitionElapsedMs = 0
    actionProc.closeAfter = shouldCloseOnSuccess === true
    actionProc.command = ["timeout", "-k", "2", "60"].concat(cmdArray)
    actionProc.running = true
  }

  function toggleMode() {
    if (isHomelabMode) {
      startTransition("Restoring desktop profile...", ["oma-server", "disable"], false)
    } else {
      var args = ["oma-server", "enable", "-y"]
      if (selectedTimeout !== "" && selectedTimeout !== "0") {
        args.push("--timeout")
        args.push(selectedTimeout)
      }
      startTransition("Switching to Homelab mode...", args, true)
    }
  }

  function runRescue() {
    startTransition("Running emergency rescue...", ["oma-server", "rescue"], false)
  }

  function inTerminal(cmd) {
    if (bar) bar.run("omarchy-launch-floating-terminal-with-presentation " + cmd)
    root.close()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function prepareHomelabFreeze(): string {
      root.isTransitioning = false
      root.isHomelabMode = true
      root.currentMode = "HOMELAB_MODE"
      root.dpmsStatus = "OFF (Power Saving)"
      root.quickshellStatus = "Suspended (0 CPU)"
      root.healthStatus = "OK"
      root.errorNotice = ""
      root.recoveryHint = ""
      root.close()
      return "ok"
    }
  }

  Process {
    id: statusProc
    command: ["timeout", "-k", "2", "15", "oma-server", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.isHomelabMode = data.is_homelab === true
          root.currentMode = String(data.mode || "HOST_LAPTOP")
          root.sinceTime = String(data.since || "Desktop profile")
          root.elapsedHuman = String(data.elapsed_human || "00h 00m 00s")
          root.inhibitorStatus = String(data.inhibitor || "Inactive")
          root.timeoutStatus = String(data.timeout_status || "Standby")
          root.dpmsStatus = String(data.dpms || "ON (Active)")
          root.quickshellStatus = String(data.quickshell || "Running")
          root.protectedActive = Number(data.protected_active) || 0
          root.protectedTotal = Number(data.protected_total) || 10
          root.healthStatus = String(data.health || "OK")
          root.deepAllowed = data.deep_allowed === true
          root.deepNotice = ""
          var ld = data.last_deep
          if (ld && (ld.result === "exited" || ld.result === "greeter") && ld.exited_at) {
            var ageSec = Math.floor(Date.now() / 1000) - Number(ld.exited_at)
            if (ageSec >= 0 && ageSec < 600) {
              var dur = Number(ld.duration_seconds) || 0
              var h = Math.floor(dur / 3600)
              var m = Math.floor((dur % 3600) / 60)
              var freed = (ld.freed_mb !== null && ld.freed_mb !== undefined)
                ? (" · freed " + (Number(ld.freed_mb) / 1024).toFixed(1) + " GiB") : ""
              root.deepNotice = "Back from Deep Server · " + h + "h" + (m < 10 ? "0" : "") + m + "m" + freed
            }
          }
          root.loaded = true
          if (root.healthStatus === "DEGRADED" && root.errorNotice === "") {
            root.errorNotice = "Inhibitor process is stale while Homelab snapshot is active."
            root.recoveryHint = "Use Rescue below or run 'oma-server rescue' to resynchronize."
          } else if (root.healthStatus === "OK" && root.errorNotice.indexOf("stale") >= 0) {
            root.errorNotice = ""
            root.recoveryHint = ""
          }
        } catch (e) {
          root.errorNotice = "Telemetry parse error during status poll."
          root.recoveryHint = "Verify 'oma-server status --json' output in terminal."
        }
      }
    }
  }

  Process {
    id: actionProc
    property bool closeAfter: false
    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: actionStderr
      waitForEnd: true
    }
    onExited: function(exitCode, exitStatus) {
      root.transitionProgress = 100
      root.isTransitioning = false
      if (exitCode !== 0) {
        var errTxt = String(actionStderr.text || "").replace(/\x1b\[[0-9;]*m/g, "").trim()
        root.errorNotice = errTxt !== "" ? errTxt.split("\n")[0] : ("Operation exited with code " + String(exitCode))
        root.recoveryHint = "Use Rescue to restore baseline or inspect CLI logs."
      } else {
        root.errorNotice = ""
        root.recoveryHint = ""
        if (actionProc.closeAfter) {
          root.close()
        }
      }
      root.refresh()
    }
  }

  Timer {
    id: spinnerTimer
    interval: 80
    running: root.isTransitioning || (!root.loaded && statusProc.running)
    repeat: true
    onTriggered: {
      root.spinnerIndex = (root.spinnerIndex + 1) % root.spinnerFrames.length
      if (root.isTransitioning) {
        root.transitionElapsedMs += 80
        if (root.transitionProgress < 90 && (root.transitionElapsedMs % 160 === 0)) {
          root.transitionProgress = Math.min(90, root.transitionProgress + 10)
        }
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.opened ? 2000 : 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) refresh()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.isTransitioning
      ? root.transitionLabel
      : (root.isHomelabMode ? "Homelab Mode · Screen Off (" + root.elapsedHuman + ")" : "Laptop Mode · Screen Lit")
    onPressed: function(code) {
      root.toggle()
    }

    iconComponent: Component {
      LaptopScreenIcon {
        anchors.fill: parent
        lit: !root.isHomelabMode
        syncing: root.isTransitioning
        strokeColor: root.isHomelabMode ? Qt.darker(root.barForeground, 1.35) : root.barForeground
        litColor: root.barForeground
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: column
          width: flick.width
          spacing: Style.space(14)

          // ---------- 1. Hero Header ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.height, heroLabels.implicitHeight, statusPill.height)

            LaptopScreenIcon {
              id: heroIcon
              width: Style.space(28)
              height: Style.space(28)
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              lit: !root.isHomelabMode
              syncing: root.isTransitioning
              strokeColor: root.isHomelabMode ? root.dim : root.foreground
              litColor: root.accent
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: statusPill.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "Oma Server"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.isTransitioning
                  ? root.transitionLabel.toUpperCase()
                  : (root.isHomelabMode ? ("HOMELAB MODE · " + root.elapsedHuman) : "LAPTOP MODE · SCREEN LIT")
                color: root.isHomelabMode ? root.okColor : Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.1
                elide: Text.ElideRight
                width: parent.width
              }
            }

            Rectangle {
              id: statusPill
              height: badgeLabel.implicitHeight + Style.space(6)
              width: badgeLabel.implicitWidth + Style.space(14)
              radius: height / 2
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              color: Qt.rgba(badgeLabel.color.r, badgeLabel.color.g, badgeLabel.color.b, 0.14)
              border.width: 1
              border.color: Qt.rgba(badgeLabel.color.r, badgeLabel.color.g, badgeLabel.color.b, 0.45)

              Text {
                id: badgeLabel
                textFormat: Text.PlainText
                anchors.centerIn: parent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                text: root.isTransitioning
                  ? "SYNCING"
                  : (root.errorNotice !== ""
                    ? "ERROR"
                    : (root.healthStatus === "DEGRADED"
                      ? "DEGRADED"
                      : (root.isHomelabMode ? "HOMELAB" : "LAPTOP")))
                color: root.isTransitioning
                  ? root.syncColor
                  : (root.errorNotice !== ""
                    ? root.urgent
                    : (root.healthStatus === "DEGRADED"
                      ? root.warnColor
                      : (root.isHomelabMode ? root.okColor : root.accent)))
              }
            }
          }

          // ---------- 2. Smooth Progress Bar (Shown During Transitions) ----------
          Column {
            visible: root.isTransitioning || (!root.loaded && statusProc.running)
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Style.space(6)

              Rectangle {
                id: barTrack
                anchors.fill: parent
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
              }

              Rectangle {
                anchors.left: barTrack.left
                anchors.verticalCenter: barTrack.verticalCenter
                height: barTrack.height
                radius: barTrack.radius
                color: root.accent
                width: Math.max(barTrack.height, barTrack.width * ((root.isTransitioning ? root.transitionProgress : 50) / 100.0))

                Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
              }
            }

            Row {
              width: parent.width

              Text {
                textFormat: Text.PlainText
                text: root.isTransitioning ? root.transitionLabel : "Polling system telemetry..."
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }

              Item {
                width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
                height: 1
              }

              Text {
                textFormat: Text.PlainText
                text: root.formatElapsedTenths(root.transitionElapsedMs)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }
            }
          }

          // ---------- 2b. Deep Server return notice ----------
          Text {
            visible: root.deepNotice !== ""
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.deepNotice
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.dim
          }

          // ---------- 3. Error / Degraded Notice ----------
          Rectangle {
            visible: root.errorNotice !== ""
            width: parent.width
            height: errCol.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.50)

            Column {
              id: errCol
              anchors.fill: parent
              anchors.margins: Style.space(7)
              spacing: Style.space(3)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.errorNotice
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: root.healthStatus === "DEGRADED" ? root.warnColor : root.urgent
              }

              Text {
                visible: root.recoveryHint !== ""
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.recoveryHint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // ---------- 4. Subsystem Telemetry ----------
          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair {
              label: "Sleep & lid inhibit"
              value: root.inhibitorStatus
              valueColor: root.inhibitorStatus.indexOf("Active") === 0 ? root.okColor : (root.inhibitorStatus === "Stale" ? root.warnColor : root.foreground)
            }

            InfoPair {
              label: "Display output"
              value: root.dpmsStatus
              valueColor: root.dpmsStatus.indexOf("OFF") === 0 ? root.okColor : root.foreground
            }

            InfoPair {
              label: "Shell event loop"
              value: root.quickshellStatus
              valueColor: root.quickshellStatus.indexOf("Suspended") === 0 ? root.okColor : root.foreground
            }

            InfoPair {
              label: "Auto-revert timer"
              value: root.timeoutStatus
              valueColor: root.timeoutStatus.indexOf("Active") === 0 ? root.okColor : root.foreground
            }

            InfoPair {
              label: "Protected services"
              value: String(root.protectedActive) + " / " + String(root.protectedTotal) + " active"
              valueColor: root.foreground
            }

            InfoPair {
              visible: root.isHomelabMode
              label: "Active since"
              value: root.sinceTime
              valueColor: root.foreground
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // ---------- 5. Auto-Revert Timer Selector ----------
          Column {
            visible: !root.isHomelabMode
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "AUTO-REVERT TIMER"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.timeoutPresets
                delegate: Button {
                  required property var modelData
                  width: (parent.width - Style.space(6) * 4) / 5
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  horizontalPadding: Style.space(4)
                  bordered: true
                  active: root.selectedTimeout === modelData.value
                  selected: root.selectedTimeout === modelData.value
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  text: modelData.label
                  onClicked: root.selectedTimeout = modelData.value
                }
              }
            }
          }

          // ---------- 6. Primary Mode Transition Button ----------
          Button {
            width: parent.width
            enabled: !root.isTransitioning
            fontSize: Style.font.body
            verticalPadding: Style.space(9)
            horizontalPadding: Style.space(12)
            bordered: true
            active: root.isHomelabMode
            selected: root.isHomelabMode
            foreground: root.foreground
            fontFamily: root.fontFamily
            text: root.isTransitioning
              ? (root.spinnerChar + "  " + root.transitionLabel)
              : (root.isHomelabMode
                ? "Restore Desktop Mode"
                : ("Enable Homelab Mode" + (root.selectedTimeout !== "0" ? " (" + root.selectedTimeout + ")" : "")))
            onClicked: root.toggleMode()
          }

          // ---------- 7. Secondary Controls ----------
          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              width: (parent.width - Style.space(16)) / 3
              enabled: !root.isTransitioning
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Plan Diff"
              tooltipText: "Open in-memory transition diff and Tier-0 service audit in terminal"
              onClicked: root.inTerminal("oma-server diff")
            }

            Button {
              width: (parent.width - Style.space(16)) / 3
              enabled: !root.isTransitioning
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Refresh"
              tooltipText: "Poll live compositor, DPMS, and inhibitor telemetry now"
              onClicked: root.refresh()
            }

            Button {
              width: (parent.width - Style.space(16)) / 3
              enabled: !root.isTransitioning
              fontSize: Style.font.bodySmall
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              foreground: root.urgent
              fontFamily: root.fontFamily
              text: "Rescue"
              tooltipText: "Emergency recovery: unfreeze Quickshell, wake displays, purge locks"
              onClicked: root.runRescue()
            }
          }

          // ---------- 8. Deep Server Mode (opt-in, always via a terminal) ----------
          // Never one-click: confirmation, any typed 'yes' and sudo prompts happen
          // in Omarchy's floating terminal, like its own setup actions.
          Button {
            width: parent.width
            enabled: !root.isTransitioning && !root.isHomelabMode
            fontSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            text: root.deepAllowed ? "Deep Server Mode…" : "Set up Deep Server Mode…"
            tooltipText: root.deepAllowed
              ? "Stop the desktop and greeter (headless). Shows the plan first; open windows need a typed 'yes'."
              : "Run 'oma-server deep-setup' in a terminal (installs a fixed-verb root helper; sudo prompt)."
            onClicked: root.deepAllowed
              ? root.inTerminal("'oma-server diff --deep && oma-server enable --deep'")
              : root.inTerminal("'oma-server deep-setup'")
          }
        }
      }
    }
  }

  // Crisp vector laptop icon whose screen is illuminated in Laptop Mode
  // and dark/off in Homelab Mode (reflecting DPMS display powerdown).
  component LaptopScreenIcon: Item {
    id: iconRoot
    property bool lit: true
    property bool syncing: false
    property color strokeColor: root.barForeground
    property color litColor: root.barForeground
    property real pulseOpacity: 0.85

    SequentialAnimation on pulseOpacity {
      running: iconRoot.syncing
      loops: Animation.Infinite
      NumberAnimation { from: 0.90; to: 0.15; duration: 420; easing.type: Easing.InOutSine }
      NumberAnimation { from: 0.15; to: 0.90; duration: 420; easing.type: Easing.InOutSine }
    }

    // Laptop display lid / bezel
    Rectangle {
      id: screenBezel
      width: Math.round(iconRoot.width * 0.82)
      height: Math.round(iconRoot.height * 0.58)
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: parent.top
      anchors.topMargin: Math.round(iconRoot.height * 0.13)
      radius: Math.max(2, Math.round(iconRoot.width * 0.10))
      color: "transparent"
      border.width: Math.max(1.5, Math.round(iconRoot.width * 0.09))
      border.color: iconRoot.strokeColor

      Behavior on border.color { ColorAnimation { duration: 180 } }

      // Illuminated inner LCD panel when in Laptop Mode
      Rectangle {
        id: screenPanel
        anchors.fill: parent
        anchors.margins: Math.max(2, Math.round(screenBezel.border.width + 1))
        radius: Math.max(1, screenBezel.radius - 1)
        color: iconRoot.litColor
        opacity: iconRoot.syncing ? iconRoot.pulseOpacity : (iconRoot.lit ? 0.92 : 0.0)

        Behavior on opacity {
          enabled: !iconRoot.syncing
          NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
        }
        Behavior on color { ColorAnimation { duration: 180 } }
      }
    }

    // Laptop keyboard deck / base
    Rectangle {
      width: Math.round(iconRoot.width * 0.98)
      height: Math.max(2, Math.round(iconRoot.height * 0.12))
      radius: height / 2
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: screenBezel.bottom
      anchors.topMargin: Math.max(1, Math.round(iconRoot.height * 0.04))
      color: iconRoot.strokeColor

      Behavior on color { ColorAnimation { duration: 180 } }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property color valueColor: root.foreground

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: parent.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
