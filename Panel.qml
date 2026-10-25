import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Oma Server bar button and telemetry/control dashboard popup.
// Enforces a strict Zero-Emoji Policy: visual hierarchy is achieved via
// monospace typography, ANSI-inspired semantic tokens, box-drawing chrome,
// Braille geometric spinners, segmented progress bars, and bracketed badges.
Panel {
  id: root
  moduleName: "rohirik.oma-server"
  ipcTarget: "rohirik.oma-server"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color okColor: "#4ec978"
  readonly property color warnColor: "#e5c07b"
  readonly property color infoColor: "#61afef"
  readonly property color syncColor: "#c678dd"
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

  // Interactive Controls & Async Progress State
  property string selectedTimeout: "0"
  readonly property var timeoutPresets: [
    { label: "OFF", value: "0" },
    { label: "30M", value: "30m" },
    { label: "1H",  value: "1h" },
    { label: "2H",  value: "2h" },
    { label: "4H",  value: "4h" }
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

  function renderAsciiProgress(pct) {
    var clamped = Math.max(0, Math.min(100, Number(pct) || 0))
    var filled = Math.round(clamped / 10)
    var empty = 10 - filled
    var out = "["
    for (var i = 0; i < filled; i++) out += "█"
    for (var j = 0; j < empty; j++) out += "░"
    out += "] " + String(clamped) + "%"
    return out
  }

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
    actionProc.command = ["timeout", "-k", "2", "10"].concat(cmdArray)
    actionProc.running = true
  }

  function toggleMode() {
    if (isHomelabMode) {
      startTransition("Restoring HOST_LAPTOP profile...", ["oma-server", "disable"], false)
    } else {
      var args = ["oma-server", "enable", "-y"]
      if (selectedTimeout !== "" && selectedTimeout !== "0") {
        args.push("--timeout")
        args.push(selectedTimeout)
      }
      startTransition("Engaging HOMELAB_MODE guardrails...", args, true)
    }
  }

  function runRescue() {
    startTransition("Executing Emergency Rescue sequence...", ["oma-server", "rescue"], false)
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
  }

  Process {
    id: statusProc
    command: ["timeout", "-k", "2", "4", "oma-server", "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          root.isHomelabMode = data.is_homelab === true
          root.currentMode = String(data.mode || "HOST_LAPTOP")
          root.sinceTime = String(data.since || "N/A (Desktop Profile)")
          root.elapsedHuman = String(data.elapsed_human || "00h 00m 00s")
          root.inhibitorStatus = String(data.inhibitor || "Inactive")
          root.timeoutStatus = String(data.timeout_status || "Standby")
          root.dpmsStatus = String(data.dpms || "ON (Active)")
          root.quickshellStatus = String(data.quickshell || "Running")
          root.protectedActive = Number(data.protected_active) || 0
          root.protectedTotal = Number(data.protected_total) || 10
          root.healthStatus = String(data.health || "OK")
          root.loaded = true
          if (root.healthStatus === "DEGRADED" && root.errorNotice === "") {
            root.errorNotice = "Inhibitor process is stale while Homelab snapshot is active."
            root.recoveryHint = "Click [ RESCUE ] below or run 'oma-server rescue' to resynchronize."
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
        root.recoveryHint = "Use [ RESCUE ] to force baseline restoration or inspect CLI logs."
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
    text: root.isTransitioning ? root.spinnerChar : (root.isHomelabMode ? "◆" : "◇")
    active: root.isHomelabMode
    tooltipText: "OMA-SERVER // " + (
      root.isTransitioning
        ? "[ SYNCING ] " + root.transitionLabel
        : (root.isHomelabMode ? "[ OK ] HOMELAB_MODE (" + root.elapsedHuman + ")" : "[ INFO ] HOST_LAPTOP")
    )
    onPressed: function(code) {
      root.toggle()
    }

    Rectangle {
      visible: root.isHomelabMode || root.healthStatus === "DEGRADED"
      width: Style.space(6)
      height: width
      radius: width / 2
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(2)
      color: root.healthStatus === "DEGRADED" ? root.warnColor : root.okColor
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
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
          spacing: Style.space(10)

          // ---------- 1. Structured Dashboard Header ----------
          Rectangle {
            width: parent.width
            height: headerCol.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
            border.width: 1
            border.color: root.isHomelabMode
              ? Qt.rgba(root.okColor.r, root.okColor.g, root.okColor.b, 0.45)
              : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

            Column {
              id: headerCol
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(4)

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: root.isTransitioning ? root.spinnerChar : (root.isHomelabMode ? "◆" : "◇")
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  color: root.isTransitioning
                    ? root.syncColor
                    : (root.isHomelabMode ? root.okColor : root.accent)
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: "OMA-SERVER // NODE CONTROLLER"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  color: root.foreground
                  anchors.verticalCenter: parent.verticalCenter
                }

                Item {
                  width: Math.max(0, parent.width - parent.children[0].width - parent.children[1].width - statusPill.width - Style.space(24))
                  height: 1
                }

                Rectangle {
                  id: statusPill
                  height: badgeLabel.implicitHeight + Style.space(4)
                  width: badgeLabel.implicitWidth + Style.space(10)
                  radius: Style.cornerRadius
                  anchors.verticalCenter: parent.verticalCenter
                  color: Qt.rgba(badgeLabel.color.r, badgeLabel.color.g, badgeLabel.color.b, 0.14)
                  border.width: 1
                  border.color: Qt.rgba(badgeLabel.color.r, badgeLabel.color.g, badgeLabel.color.b, 0.55)

                  Text {
                    id: badgeLabel
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    text: root.isTransitioning
                      ? "[ SYNCING ]"
                      : (root.errorNotice !== ""
                        ? "[ FAIL ]"
                        : (root.healthStatus === "DEGRADED"
                          ? "[ WARN ]"
                          : (root.isHomelabMode ? "[ OK ]" : "[ INFO ]")))
                    color: root.isTransitioning
                      ? root.syncColor
                      : (root.errorNotice !== ""
                        ? root.urgent
                        : (root.healthStatus === "DEGRADED"
                          ? root.warnColor
                          : (root.isHomelabMode ? root.okColor : root.infoColor)))
                  }
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: root.isHomelabMode
                    ? "PROFILE: HOMELAB_MODE (HEADLESS COMPUTE)"
                    : "PROFILE: HOST_LAPTOP (INTERACTIVE DESKTOP)"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.isHomelabMode ? root.okColor : root.dim
                }

                Item {
                  width: Math.max(0, parent.width - parent.children[0].width - uptimeLabel.width - Style.space(16))
                  height: 1
                }

                Text {
                  id: uptimeLabel
                  textFormat: Text.PlainText
                  text: root.isHomelabMode ? ("ELAPSED " + root.elapsedHuman) : "IDLE 00h 00m 00s"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                }
              }
            }
          }

          // ---------- 2. Dynamic Async Progress & Loader Banner ----------
          Rectangle {
            visible: root.isTransitioning || (!root.loaded && statusProc.running)
            width: parent.width
            height: progressCol.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Qt.rgba(root.syncColor.r, root.syncColor.g, root.syncColor.b, 0.08)
            border.width: 1
            border.color: Qt.rgba(root.syncColor.r, root.syncColor.g, root.syncColor.b, 0.4)

            Column {
              id: progressCol
              anchors.fill: parent
              anchors.margins: Style.space(7)
              spacing: Style.space(4)

              Row {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: root.spinnerChar + " [ SYNCING ]"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: root.syncColor
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.isTransitioning ? root.transitionLabel : "Polling system telemetry..."
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                  elide: Text.ElideRight
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: root.renderAsciiProgress(root.isTransitioning ? root.transitionProgress : 50)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: root.accent
                }

                Text {
                  textFormat: Text.PlainText
                  text: "│ ELAPSED " + root.formatElapsedTenths(root.transitionElapsedMs)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.dim
                }
              }
            }
          }

          // ---------- 3. Inline Error / Degraded Recovery Banner ----------
          Rectangle {
            visible: root.errorNotice !== ""
            width: parent.width
            height: errCol.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            border.width: 1
            border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.55)

            Column {
              id: errCol
              anchors.fill: parent
              anchors.margins: Style.space(7)
              spacing: Style.space(3)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: (root.healthStatus === "DEGRADED" ? "[ WARN ] " : "[ FAIL ] ") + root.errorNotice
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
                text: "└─ Hint: " + root.recoveryHint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
              }
            }
          }

          // ---------- 4. Box-Drawn Telemetry & Guardrail Matrix ----------
          Rectangle {
            width: parent.width
            height: telemetryCol.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

            Column {
              id: telemetryCol
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(5)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "┌─ SUBSYSTEM TELEMETRY & SAFETY GUARDRAILS ────────┐"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                color: root.dim
                elide: Text.ElideRight
              }

              Repeater {
                model: [
                  {
                    key: "│ Power / Lid Inhibit",
                    badge: root.inhibitorStatus.indexOf("Active") === 0 ? "[ OK ]" : (root.inhibitorStatus === "Stale" ? "[ WARN ]" : "[ STANDBY ]"),
                    badgeColor: root.inhibitorStatus.indexOf("Active") === 0 ? root.okColor : (root.inhibitorStatus === "Stale" ? root.warnColor : root.dim),
                    val: root.inhibitorStatus
                  },
                  {
                    key: "│ Display Output",
                    badge: root.dpmsStatus.indexOf("OFF") === 0 ? "[ OK ]" : "[ INFO ]",
                    badgeColor: root.dpmsStatus.indexOf("OFF") === 0 ? root.okColor : root.infoColor,
                    val: root.dpmsStatus
                  },
                  {
                    key: "│ Quickshell Loop",
                    badge: root.quickshellStatus.indexOf("Suspended") === 0 ? "[ OK ]" : "[ INFO ]",
                    badgeColor: root.quickshellStatus.indexOf("Suspended") === 0 ? root.okColor : root.infoColor,
                    val: root.quickshellStatus
                  },
                  {
                    key: "│ Dead-Man Timer",
                    badge: root.timeoutStatus.indexOf("Active") === 0 ? "[ OK ]" : "[ STANDBY ]",
                    badgeColor: root.timeoutStatus.indexOf("Active") === 0 ? root.okColor : root.dim,
                    val: root.timeoutStatus
                  },
                  {
                    key: "│ Tier-0 Whitelist",
                    badge: "[ GUARDED ]",
                    badgeColor: root.infoColor,
                    val: String(root.protectedActive) + "/" + String(root.protectedTotal) + " active"
                  },
                  {
                    key: "│ Active Since",
                    badge: root.isHomelabMode ? "[ OK ]" : "[ INFO ]",
                    badgeColor: root.isHomelabMode ? root.okColor : root.dim,
                    val: root.sinceTime
                  }
                ]

                delegate: Row {
                  required property var modelData
                  width: telemetryCol.width
                  spacing: Style.space(6)

                  Text {
                    width: Style.space(132)
                    textFormat: Text.PlainText
                    text: modelData.key
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dim
                    elide: Text.ElideRight
                  }

                  Text {
                    width: Style.space(76)
                    textFormat: Text.PlainText
                    text: modelData.badge
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: modelData.badgeColor
                  }

                  Text {
                    width: Math.max(0, parent.width - Style.space(220))
                    textFormat: Text.PlainText
                    text: modelData.val
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                    elide: Text.ElideRight
                  }
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "└──────────────────────────────────────────────────┘"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.dim
                elide: Text.ElideRight
              }
            }
          }

          // ---------- 5. Dead Man's Switch (Auto-Revert Timer) Selector ----------
          Column {
            visible: !root.isHomelabMode
            width: parent.width
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: "DEAD MAN'S SWITCH // AUTO-REVERT TIMEOUT PRESET"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.dim
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.timeoutPresets
                delegate: Button {
                  required property var modelData
                  width: (parent.width - Style.space(6) * 4) / 5
                  fontSize: Style.font.caption
                  verticalPadding: Style.space(5)
                  horizontalPadding: Style.space(4)
                  bordered: true
                  selected: root.selectedTimeout === modelData.value
                  fontFamily: root.fontFamily
                  text: "[ " + modelData.label + " ]"
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
            selected: root.isHomelabMode
            fontFamily: root.fontFamily
            text: root.isTransitioning
              ? (root.spinnerChar + "  [ SYNCING ] EXECUTING TRANSITION...")
              : (root.isHomelabMode
                ? "▸ [ RESTORE ] RETURN TO HOST_LAPTOP MODE"
                : ("▸ [ ENABLE ] SWITCH TO HOMELAB_MODE" + (root.selectedTimeout !== "0" ? " (" + root.selectedTimeout.toUpperCase() + ")" : "")))
            onClicked: root.toggleMode()
          }

          // ---------- 7. Secondary Diagnostic & Emergency Controls ----------
          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              width: (parent.width - Style.space(16)) / 3
              enabled: !root.isTransitioning
              fontSize: Style.font.caption
              verticalPadding: Style.space(6)
              bordered: true
              fontFamily: root.fontFamily
              text: "[ DIFF ] PLAN"
              tooltipText: "Open in-memory transition diff & Tier-0 service audit in terminal"
              onClicked: root.inTerminal("oma-server diff")
            }

            Button {
              width: (parent.width - Style.space(16)) / 3
              enabled: !root.isTransitioning
              fontSize: Style.font.caption
              verticalPadding: Style.space(6)
              bordered: true
              fontFamily: root.fontFamily
              text: "[ SYNC ] REFRESH"
              tooltipText: "Poll live compositor, DPMS, and inhibitor telemetry now"
              onClicked: root.refresh()
            }

            Button {
              width: (parent.width - Style.space(16)) / 3
              enabled: !root.isTransitioning
              fontSize: Style.font.caption
              verticalPadding: Style.space(6)
              bordered: true
              foreground: root.urgent
              fontFamily: root.fontFamily
              text: "[ RESCUE ] RESET"
              tooltipText: "Emergency recovery: unfreeze Quickshell, wake displays, purge locks"
              onClicked: root.runRescue()
            }
          }
        }
      }
    }
  }
}
