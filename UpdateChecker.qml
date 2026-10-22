import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Manual, battery-friendly update check for this git-managed plugin. Nothing
// runs until the user asks: no startup fetch and no background polling.
Item {
  id: root
  visible: false

  property string pluginId: "markbusai.opencode-usage"
  property string pluginVersion: "1.1.0"
  property bool checking: false
  property bool updating: false
  property bool updateAvailable: false
  property bool dirty: false
  property bool failed: false
  property string statusText: ""

  readonly property bool busy: checking || updating
  readonly property string versionText: "v" + pluginVersion

  readonly property string pluginRoot: {
    var path = String(Qt.resolvedUrl("manifest.json"))
    if (path.indexOf("file://") === 0) path = path.substring(7)
    try { path = decodeURIComponent(path) } catch (e) {}
    return path.replace(/\/manifest\.json$/, "")
  }

  readonly property string checkScriptPath: {
    var path = String(Qt.resolvedUrl("scripts/check_update.sh"))
    if (path.indexOf("file://") === 0) path = path.substring(7)
    try { path = decodeURIComponent(path) } catch (e) {}
    return path
  }

  function check() {
    if (busy) return
    checking = true
    failed = false
    updateAvailable = false
    dirty = false
    statusText = "Checking for updates…"
    checkProcess.command = ["bash", checkScriptPath, pluginRoot]
    checkProcess.running = true
  }

  function installUpdate() {
    if (busy || !updateAvailable) return
    updating = true
    failed = false
    statusText = dirty ? "Updating (local changes may block it)…" : "Updating…"
    updateProcess.command = ["omarchy", "plugin", "update", pluginId, "--yes"]
    updateProcess.running = true
  }

  function applyCheck(output, errorOutput, exitCode) {
    checking = false
    var text = String(output || "").trim()
    if (text === "") {
      failed = true
      updateAvailable = false
      var error = String(errorOutput || "").trim()
      var lastError = error !== "" ? error.split("\n").pop().trim() : ""
      statusText = "Check failed" + (lastError !== "" ? ": " + lastError : "")
      return
    }

    var fields = text.split("\t")
    var state = String(fields[0] || "error")
    var detail = String(fields[1] || "")
    dirty = fields.length > 2 && String(fields[2]) === "1"

    if (state === "current") {
      failed = false
      updateAvailable = false
      statusText = dirty ? "Up to date · local changes present" : "Up to date"
    } else if (state === "available") {
      failed = false
      updateAvailable = true
      statusText = "Update available" + (detail !== "" ? ": " + detail : "")
        + (dirty ? " · local changes may block it" : "")
    } else if (state === "ahead") {
      failed = false
      updateAvailable = false
      statusText = "Local build is ahead of origin"
    } else if (state === "diverged") {
      failed = false
      updateAvailable = false
      statusText = "Local and remote histories diverged"
    } else if (state === "error") {
      failed = true
      updateAvailable = false
      statusText = detail !== "" ? detail : "Could not check for updates"
    } else {
      failed = true
      updateAvailable = false
      statusText = exitCode === 0 ? "Unexpected update check result" : "Check failed"
    }
  }

  function applyUpdate(exitCode) {
    updating = false
    if (exitCode === 0) {
      failed = false
      updateAvailable = false
      dirty = false
      statusText = "Updated — reloading…"
      manifestFile.reload()
      return
    }
    failed = true
    var detail = String(updateStderr.text || updateStdout.text || "").trim()
    var lastLine = detail !== "" ? detail.split("\n").pop().trim() : ""
    statusText = "Update failed" + (lastLine !== "" ? ": " + lastLine : "")
  }

  FileView {
    id: manifestFile
    path: root.pluginRoot + "/manifest.json"
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var manifest = JSON.parse(text())
        if (manifest && manifest.version) root.pluginVersion = String(manifest.version)
      } catch (e) {}
    }
  }

  Process {
    id: checkProcess
    running: false
    command: []
    stdout: StdioCollector { id: checkStdout; waitForEnd: true }
    stderr: StdioCollector { id: checkStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyCheck(checkStdout.text, checkStderr.text, exitCode)
    }
  }

  Process {
    id: updateProcess
    running: false
    command: []
    stdout: StdioCollector { id: updateStdout; waitForEnd: true }
    stderr: StdioCollector { id: updateStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyUpdate(exitCode)
    }
  }
}
