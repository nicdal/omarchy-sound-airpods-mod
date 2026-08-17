import QtQuick
import Quickshell
import Quickshell.Io

// Shared AirPods state for the Sound panel.
//
// This is a `service`, which the Omarchy shell loads exactly once, unlike a
// `bar-widget` -- the bar is built with `Variants { model: Quickshell.screens }`,
// so a widget is instantiated per monitor. Keeping the airpods.py stream here
// means one bridge process no matter how many monitors are attached. Running it
// inside the widget spawned one per screen, each with its own `connected` flag,
// and the widget flickered whenever the two disagreed.
Item {
  id: root

  // Injected by the shell.
  property var shell: null

  // ANC bitmask values as MagicPodsCore reports them.
  readonly property int ancOff: 1
  readonly property int ancTransparency: 2
  readonly property int ancNoiseCancellation: 16

  property bool connected: false
  property string deviceName: ""
  property string address: ""
  // [{ label: "Left"|"Right"|"Case"|"Battery", pct: int, charging: bool }]
  property var batteryComponents: []
  property int ancOptions: 0
  property int ancSelected: 0

  // The mode a click asked for, held until the daemon confirms it. Without this
  // the pill snaps back to the old mode for the round-trip, which reads as the
  // click having missed.
  property int pendingAnc: 0
  readonly property int effectiveAnc: pendingAnc > 0 ? pendingAnc : ancSelected

  // The bar shows the bud that will die first. The case is excluded -- it isn't
  // what runs out mid-call.
  readonly property int lowestBattery: {
    var lowest = -1
    for (var i = 0; i < batteryComponents.length; i++) {
      var component = batteryComponents[i]
      if (component.label === "Case") continue
      if (component.pct === undefined || component.pct === null) continue
      if (lowest < 0 || component.pct < lowest) lowest = component.pct
    }
    return lowest
  }

  readonly property bool anyCharging: {
    for (var i = 0; i < batteryComponents.length; i++)
      if (batteryComponents[i].charging) return true
    return false
  }

  // Demo mode: a synthetic device so the panel can be worked on with no AirPods
  // present. Toggle with: omarchy bar set community.sound-airpods-mod demo true --json
  property bool demo: false

  // airpods.py lives next to this file; Process needs a path, not a URL.
  readonly property string scriptPath: {
    const url = Qt.resolvedUrl("airpods.py").toString()
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  readonly property var streamCommand: ["python3", scriptPath, demo ? "demo" : "watch"]

  function applyState(line) {
    if (!line) return
    var state
    try {
      state = JSON.parse(line)
    } catch (e) {
      return
    }

    connected = !!state.connected
    deviceName = state.name || ""
    address = state.address || ""
    batteryComponents = state.battery || []

    if (state.anc) {
      ancOptions = state.anc.options || 0
      ancSelected = state.anc.selected || 0
      // The daemon has caught up, so stop overriding it.
      if (pendingAnc > 0 && pendingAnc === ancSelected) pendingAnc = 0
    } else {
      ancOptions = 0
      ancSelected = 0
      pendingAnc = 0
    }

    if (!connected) pendingAnc = 0
  }

  function setAnc(mode) {
    if (!mode || mode === effectiveAnc) return
    pendingAnc = mode
    ancProc.command = ["python3", scriptPath, "set-anc", String(mode)].concat(demo ? ["--demo"] : [])
    ancProc.running = true
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
}
