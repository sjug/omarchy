pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking

// One observer for every monitor's panel. Native Networking supports only
// NetworkManager and logs an error when constructed without its D-Bus owner.
// Other hosts retain their network manager and expose route status instead.
Singleton {
  id: root

  property bool backendKnown: false
  property bool hasNetworkManager: false
  readonly property var networking: hasNetworkManager ? Networking : null
  readonly property bool observeRoutes: backendKnown && !hasNetworkManager
  property string kind: "disconnected"
  property string connectionName: ""
  property int signalStrength: -1
  property int generation: 0
  property int readGeneration: -1
  property bool readAgain: false

  function backendChanged(available) {
    generation++
    hasNetworkManager = available
    backendKnown = true
    kind = "disconnected"
    connectionName = ""
    signalStrength = -1
    if (observeRoutes) refresh()
  }

  function refresh() {
    if (!observeRoutes) return
    if (reader.running) {
      readAgain = true
      return
    }
    readAgain = false
    readGeneration = generation
    reader.running = true
  }

  Process {
    id: backendEvents
    // gdbus watches name ownership and reports its initial state, closing the
    // race between a one-time probe and subscribing to subsequent changes.
    command: ["stdbuf", "-oL", "gdbus", "monitor", "--system", "--dest", "org.freedesktop.NetworkManager"]
    environment: ({ LC_ALL: "C" })
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        if (line.indexOf("The name org.freedesktop.NetworkManager ") !== 0) return
        root.backendChanged(line.indexOf(" is owned by ") !== -1)
      }
    }
  }

  Process {
    id: routeEvents
    command: ["ip", "monitor", "link", "address", "route"]
    running: root.observeRoutes
    onStarted: root.refresh()
    stdout: SplitParser {
      onRead: function(line) {
        root.generation++
        routeChanged.restart()
      }
    }
  }

  // Coalesce a netlink burst; this timer never runs while the network is idle.
  Timer {
    id: routeChanged
    interval: 75
    onTriggered: root.refresh()
  }

  Process {
    id: reader
    command: ["omarchy-network-status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (!root.observeRoutes || root.readGeneration !== root.generation) return
        var fields = String(text || "").trim().split("\t")
        root.kind = fields[0] === "ethernet" || fields[0] === "wifi" ? fields[0] : "disconnected"
        root.connectionName = root.kind !== "disconnected" ? fields[1] || "" : ""
        var strength = Number(fields[2])
        root.signalStrength = fields[2] && isFinite(strength) ? strength : -1
      }
    }
    onExited: if (root.readAgain) root.refresh()
  }
}
