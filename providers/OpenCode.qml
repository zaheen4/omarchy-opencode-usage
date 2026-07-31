import QtQuick

LocalScanner {
  providerId: "opencode"
  providerName: "OpenCode"
  scannerPath: String(Qt.resolvedUrl("../scripts/opencode_usage_scanner.py")).replace("file://", "")
  scannerArguments: providerSettings && providerSettings.dbPath ? [String(providerSettings.dbPath)] : []
  scannerProvidesLimits: false
  defaultHelpText: "Run `opencode` once to create its usage database."
}
