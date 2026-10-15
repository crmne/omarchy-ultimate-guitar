import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Runs the production helper invocation, through Quickshell's own Process,
// against a stand-in helper that only reports what reached it.
Item {
  id: root
  property string output: ""

  function start(helper) {
    var run = Model.helperInvocation({ python: "/usr/bin/python3", helper: helper, action: "search",
      value: "Marlow Fennick Paper Lighthouse", noCache: true, maxOutputBytes: 4096, timeoutSeconds: 10 })
    output = ""
    probe.command = run.command
    probe.environment = run.environment
    probe.running = true
    return JSON.stringify(run.command)
  }

  Process {
    id: probe
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.output = text }
  }
}
