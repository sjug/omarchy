import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "network" as Network

ShellRoot {
  id: test
  property bool failed: false
  function check(ok, message) {
    if (!ok) {
      failed = true
      console.log("RESULT fail " + message)
    }
  }

  QtObject {
    id: bar
    property color foreground: Commons.Color.foreground
    property color barForeground: Commons.Color.foreground
    property color urgent: Commons.Color.urgent
    property string fontFamily: Style.font.family
    property string position: "top"
    property int barSize: 24
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property var activePopout: null
    function requestPopout(owner) { activePopout = owner }
    function releasePopout(owner) { activePopout = null }
    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
    function hideTooltip(target) {}
    function showTooltip(target, text) {}
  }
  Item {
    Network.Panel { id: first; bar: bar }
    Network.Panel { id: second; bar: bar }
  }

  Process { id: change }
  function route(status) {
    change.command = ["bash", "-c", 'printf "%s\\n" "$1" >"$NETWORK_TEST_STATE/status"; printf "changed\\nchanged\\n" >"$NETWORK_TEST_STATE/events"', "change-route", status]
    change.running = true
  }

  Timer {
    interval: 350; running: true
    onTriggered: {
      test.check(first.networking === null && second.networking === null, "absent NetworkManager never constructs the native singleton")
      test.check(first.kind === "ethernet" && second.kind === "ethernet", "both panels show the routed link at startup")
      test.check(first.connectivity === "unknown", "a route is not claimed to prove Internet access")
      test.check(!first.canToggleWifi && !first.testApPoll.running, "unavailable Wi-Fi controls and signal polling stay inactive")
      test.route("disconnected\t\t\t")
      disconnected.start()
    }
  }
  Timer {
    id: disconnected; interval: 300
    onTriggered: {
      test.check(first.kind === "disconnected" && second.kind === "disconnected", "netlink removal updates every panel")
      test.route("ethernet\tuplink1\t\t")
      reconnected.start()
    }
  }
  Timer {
    id: reconnected; interval: 300
    onTriggered: {
      test.check(first.kind === "ethernet" && first.connectionKey === "ethernet:uplink1", "route restoration replaces stale connection state")
      test.check(second.connectionKey === first.connectionKey, "all monitor panels share the restored state")
      done.start()
    }
  }
  // Stay idle so the runner can detect an observer that keeps starting reads.
  Timer {
    id: done; interval: 800
    onTriggered: {
      if (!test.failed) console.log("RESULT pass")
      Qt.quit()
    }
  }
}
