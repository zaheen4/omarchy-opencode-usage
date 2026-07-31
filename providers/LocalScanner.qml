import QtQuick
import Quickshell.Io

Item {
  id: root
  visible: false

  required property string providerId
  required property string providerName
  required property string scannerPath
  property string providerIcon: "ai"
  property string defaultHelpText: ""
  property var scannerArguments: []
  property var providerSettings: ({})
  property bool scannerProvidesLimits: true
  property int backgroundRefreshIntervalMs: 0

  property bool enabled: false
  property bool ready: false
  property bool refreshing: false
  property double lastRefreshedAtMs: 0
  property bool hasLocalStats: true

  property real rateLimitPercent: -1
  property string rateLimitLabel: ""
  property string rateLimitResetAt: ""
  property real secondaryRateLimitPercent: -1
  property string secondaryRateLimitLabel: ""
  property string secondaryRateLimitResetAt: ""

  property int todayPrompts: 0
  property int todaySessions: 0
  property real todayTotalTokens: 0
  property var todayTokensByModel: ({})
  property var recentDays: []
  property int totalPrompts: 0
  property int totalSessions: 0
  property int activeDays: 0
  property var activeDates: []
  property var modelUsage: ({})

  property string tierLabel: ""
  property string usageStatusText: ""
  property string authHelpText: defaultHelpText

  Process {
    id: scanner
    command: ["python3", root.scannerPath].concat(root.scannerArguments || [])
    running: false

    stdout: StdioCollector {
      onStreamFinished: root.parseScannerOutput(text)
    }

    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") console.warn("opencode-usage/" + root.providerId, text.trim())
    }

    onExited: {
      root.refreshing = false
      root.lastRefreshedAtMs = Date.now()
    }
  }

  onEnabledChanged: if (enabled) refresh()

  Timer {
    interval: root.backgroundRefreshIntervalMs
    running: root.enabled && interval > 0
    repeat: true
    onTriggered: root.refresh()
  }

  function refresh(force) {
    if (scanner.running) return
    refreshing = true
    scanner.running = true
  }

  function refreshLimits() {
    if (scannerProvidesLimits) refresh()
  }

  function parseScannerOutput(output) {
    var raw = String(output || "").trim()
    if (raw === "") return

    try {
      var data = JSON.parse(raw.split("\n").pop())
      ready = !!data.ready
      hasLocalStats = data.hasLocalStats !== false
      todayPrompts = data.todayPrompts || 0
      todaySessions = data.todaySessions || 0
      todayTotalTokens = data.todayTotalTokens || 0
      todayTokensByModel = data.todayTokensByModel || ({})
      recentDays = data.recentDays || []
      totalPrompts = data.totalPrompts || 0
      totalSessions = data.totalSessions || 0
      activeDays = data.activeDays || 0
      activeDates = data.activeDates || []
      modelUsage = data.modelUsage || ({})
      rateLimitPercent = data.rateLimitPercent ?? -1
      rateLimitLabel = data.rateLimitLabel || ""
      rateLimitResetAt = data.rateLimitResetAt || ""
      secondaryRateLimitPercent = data.secondaryRateLimitPercent ?? -1
      secondaryRateLimitLabel = data.secondaryRateLimitLabel || ""
      secondaryRateLimitResetAt = data.secondaryRateLimitResetAt || ""
      tierLabel = data.tierLabel || ""
      usageStatusText = data.usageStatusText || ""
      authHelpText = data.authHelpText || defaultHelpText
    } catch (e) {
      console.error("opencode-usage/" + providerId, "Failed to parse scanner output:", e, raw)
      usageStatusText = providerName + " scan failed"
      authHelpText = String(e)
      ready = true
    }
  }

  function formatResetTime(isoTimestamp) {
    if (!isoTimestamp) return ""
    var diffMs = new Date(isoTimestamp).getTime() - Date.now()
    if (diffMs <= 0) return "now"
    var hours = Math.floor(diffMs / 3600000)
    var mins = Math.floor((diffMs % 3600000) / 60000)
    if (hours > 24) return Math.floor(hours / 24) + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + mins + "m"
    return mins + "m"
  }
}
