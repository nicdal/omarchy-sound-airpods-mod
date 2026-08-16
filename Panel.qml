import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// AirPods battery + listening mode, fed by MagicPodsCore through airpods.py.
Panel {
  id: root
  moduleName: "community.airpods"
  ipcTarget: "community.airpods"

  // ANC bitmask values as MagicPodsCore reports them.
  readonly property int ancOff: 1
  readonly property int ancTransparency: 2
  readonly property int ancNoiseCancellation: 16

  property bool connected: false
  property string deviceName: ""
  property var batteryComponents: []
  property int ancOptions: 0
  property int ancSelected: 0

  // The mode a click asked for, held until the daemon confirms it. Without this
  // the pill snaps back to the old mode for the round-trip, which reads as the
  // click having missed.
  property int pendingAnc: 0
  readonly property int effectiveAnc: pendingAnc > 0 ? pendingAnc : ancSelected

  // airpods.py lives next to this file; Process needs a path, not a URL.
  readonly property string scriptPath: {
    const url = Qt.resolvedUrl("airpods.py").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  // Drive the panel from a synthetic device instead of MagicPodsCore, so the
  // UI can be worked on with no AirPods in the room. Set "demo": true on this
  // widget in ~/.config/omarchy/shell.json for a buds-style device, or
  // "demo": "max" for one that reports a single battery.
  // Read as text so the JSON boolean `true` and the strings "pro"/"max" are all
  // accepted, whichever way the value was written into shell.json.
  readonly property string demoSetting: String(root.setting("demo", "")).toLowerCase()
  readonly property bool demoMode: demoSetting === "true" || demoSetting === "max" || demoSetting === "pro"
  readonly property string demoVariant: demoSetting === "max" ? "max" : "pro"

  readonly property var streamCommand: root.demoMode
    ? [root.scriptPath, "demo", root.demoVariant]
    : [root.scriptPath, "watch"]

  // The bar pushes `settings` in after this component is built, so the first
  // command is always the non-demo one and has to be corrected once the real
  // settings land. Keying the restart to the command rather than to demoMode
  // also covers switching between demo variants, where demoMode never changes.
  onStreamCommandChanged: Qt.callLater(function() {
    stateProc.running = false
    stateProc.running = true
  })

  readonly property var ancCatalogue: [
    { value: ancOff, label: "Off", icon: "󰂲" },
    { value: ancTransparency, label: "Transparency", icon: "󰋋" },
    { value: ancNoiseCancellation, label: "Noise Cancellation", icon: "󰓃" }
  ]

  // Only the modes this particular device advertises.
  readonly property var ancModes: {
    const out = []
    for (let i = 0; i < ancCatalogue.length; i++)
      if (ancOptions & ancCatalogue[i].value) out.push(ancCatalogue[i])
    return out
  }

  function ancLabel(value) {
    for (let i = 0; i < ancCatalogue.length; i++)
      if (ancCatalogue[i].value === value) return ancCatalogue[i].label
    return ""
  }

  // The bar shows the bud that will die first. The case is excluded — it isn't
  // what runs out mid-call.
  readonly property int lowestBattery: {
    let min = -1
    for (let i = 0; i < batteryComponents.length; i++) {
      const c = batteryComponents[i]
      if (c.label === "Case") continue
      if (min < 0 || c.pct < min) min = c.pct
    }
    return min
  }

  readonly property bool anyCharging: {
    for (let i = 0; i < batteryComponents.length; i++)
      if (batteryComponents[i].charging) return true
    return false
  }

  readonly property string heroStatusText: {
    if (!connected) return "DISCONNECTED"
    const mode = ancLabel(effectiveAnc)
    return mode ? mode.toUpperCase() : "CONNECTED"
  }

  function applyState(line) {
    if (!line) return
    let s
    try {
      s = JSON.parse(line)
    } catch (e) {
      return
    }

    root.connected = !!s.connected
    root.deviceName = s.name || "AirPods"
    root.batteryComponents = s.battery || []
    root.ancOptions = s.anc ? s.anc.options : 0
    root.ancSelected = s.anc ? s.anc.selected : 0
    // The reading is authoritative; drop any optimistic pick it has caught up with.
    root.pendingAnc = 0
  }

  function setAnc(mode) {
    if (!root.connected || mode === root.effectiveAnc) return
    root.pendingAnc = mode
    ancProc.command = root.demoMode
      ? [root.scriptPath, "set-anc", String(mode), "--demo"]
      : [root.scriptPath, "set-anc", String(mode)]
    ancProc.running = true
  }

  // Keyboard cursor over the listening-mode pills.
  property int selectedIndex: 0
  property bool cursorActive: false

  function moveCursorH(delta) {
    if (ancModes.length === 0) return
    let next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > ancModes.length - 1) next = ancModes.length - 1
    selectedIndex = next
  }

  function activateCursor() {
    if (selectedIndex >= 0 && selectedIndex < ancModes.length)
      setAnc(ancModes[selectedIndex].value)
  }

  // A long-lived stream: airpods.py reconnects on its own, so this stays up for
  // the life of the shell rather than being polled.
  Process {
    id: stateProc
    running: true
    command: root.streamCommand
    stdout: SplitParser {
      onRead: function(line) { root.applyState(line) }
    }
  }

  Process {
    id: ancProc
    // Clear the optimistic pick if the write failed, so the pill stops lying.
    onExited: function(exitCode) {
      if (exitCode !== 0) root.pendingAnc = 0
    }
  }

  visible: connected
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Icon and reading are drawn separately so the glyph can match the size of
  // every other bar icon while the percentage stays at label size. A single
  // `text` would force both to one size and leave the headphones undersized.
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    horizontalMargin: 6
    fixedWidth: root.bar && root.bar.vertical
      ? -1
      : content.implicitWidth + Style.spaceReal(horizontalMargin) * 2
    tooltipText: root.deviceName
    onPressed: function(b) { root.toggle() }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        text: "󰋋"
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: root.lowestBattery >= 0
        text: root.lowestBattery + "%" + (root.anyCharging ? " 󰢝" : "")
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
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
    // Wide enough that "Noise Cancellation" keeps its padding at the default
    // text size rather than crowding its own border.
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: panelColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: headphones · name/status ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroIcon
            text: "󰋋"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
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
              text: root.deviceName
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.heroStatusText
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        // ---------- Battery ----------
        PanelSeparator {
          visible: root.batteryComponents.length > 0
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.batteryComponents.length > 0

          // A device reporting one reading already labels its row "Battery",
          // so the header would only say it twice.
          PanelSectionHeader {
            visible: root.batteryComponents.length > 1
            text: "BATTERY"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: root.batteryComponents

            Item {
              required property var modelData
              width: panelColumn.width
              implicitHeight: batteryLabel.implicitHeight + Style.space(6)

              Text {
                id: batteryLabel
                text: modelData.label
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                text: modelData.pct + "%" + (modelData.charging ? "  󰢝" : "")
                color: modelData.pct <= 20 ? Color.urgent : root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }
        }

        // ---------- Listening mode ----------
        PanelSeparator {
          visible: root.ancModes.length > 0
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.ancModes.length > 0

          PanelSectionHeader {
            text: "LISTENING MODE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          // Equal thirds would starve "Noise Cancellation" while leaving "Off"
          // mostly empty, so share the row out by label length instead. The
          // constant is the padding every pill needs regardless of its text.
          Row {
            id: ancRow
            width: parent.width
            spacing: Style.spacing.xs

            readonly property int paddingWeight: 4
            readonly property real available:
              width - spacing * Math.max(root.ancModes.length - 1, 0)
            readonly property int totalWeight: {
              let total = 0
              for (let i = 0; i < root.ancModes.length; i++)
                total += root.ancModes[i].label.length + paddingWeight
              return Math.max(total, 1)
            }

            function widthFor(label) {
              return available * (label.length + paddingWeight) / totalWeight
            }

            Repeater {
              model: root.ancModes

              AncPill {
                required property var modelData
                required property int index

                mode: modelData
                modeIndex: index
                width: ancRow.widthFor(modelData.label)
              }
            }
          }
        }
      }
    }
  }

  component AncPill: Button {
    id: pill
    required property var mode
    required property int modeIndex

    text: mode.label
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.effectiveAnc === mode.value
    hasCursor: root.cursorActive && root.selectedIndex === modeIndex

    onClicked: root.setAnc(pill.mode.value)
    onHovered: function(isHovered) {
      if (!isHovered) return
      root.cursorActive = true
      root.selectedIndex = pill.modeIndex
    }
  }
}
