import QtQuick
import Quickshell

LocalScanner {
  id: provider
  providerId: "opencode"
  providerName: "OpenCode"
  scannerPath: String(Qt.resolvedUrl("../scripts/opencode_usage_scanner.py")).replace("file://", "")
  scannerArguments: providerSettings && providerSettings.dbPath ? [String(providerSettings.dbPath)] : []
  scannerProvidesLimits: false
  defaultHelpText: "Run `opencode` once to create its usage database."
  watchDir: resolveWatchDir()
  interpreterPath: providerSettings && providerSettings.interpreter ? String(providerSettings.interpreter) : "/usr/bin/python3"

  // Watch the directory the scanner will read, not just the default one.
  function resolveWatchDir() {
    var explicit = providerSettings && providerSettings.dbPath ? String(providerSettings.dbPath) : ""
    if (explicit === "") explicit = Quickshell.env("OPENCODE_DB") || Quickshell.env("OPENCODE_DATABASE") || ""
    if (explicit === "") return dataHome + "/opencode"
    var path = explicit.replace(/^~/, Quickshell.env("HOME") || "")
    var slash = path.lastIndexOf("/")
    return slash > 0 ? path.substring(0, slash) : dataHome + "/opencode"
  }
}
