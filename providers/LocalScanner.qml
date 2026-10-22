import QtQuick
import Quickshell
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

  // Battery/disk knobs. Background scans are event-driven: the watcher sleeps
  // until OpenCode writes its WAL, then one quick scan runs at most once per
  // throttle window. The safety timer is the fallback when inotify is absent.
  property string interpreterPath: "/usr/bin/python3"
  property string watchDir: ""
  property bool watchDatabase: true
  property int scanThrottleSec: 60
  property int safetyIntervalSec: 3600

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

  // Internal scan state. A scan is single-flight; a full request that arrives
  // while a quick scan runs is queued instead of dropped.
  property string scanMode: "quick"
  property string pendingMode: ""
  property bool hasFreshData: false
  property double lastScanAtMs: 0
  property bool scanScheduled: false
  property int watcherFailures: 0
  property double watcherStartedAtMs: 0

  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/share")
  readonly property string cachePath: (Quickshell.env("XDG_CACHE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.cache")) + "/omarchy/opencode-usage.json"
  readonly property string effectiveWatchDir: watchDir !== "" ? watchDir : (dataHome + "/opencode")
  readonly property int throttleMs: Math.max(15, Number(scanThrottleSec || 60)) * 1000

  Component.onCompleted: if (enabled) start()

  onEnabledChanged: {
    if (enabled) start()
    else {
      watcher.running = false
      watcherRestart.stop()
    }
  }

  onWatchDatabaseChanged: {
    if (!watchDatabase) {
      watcher.running = false
      watcherRestart.stop()
    } else if (enabled) {
      startWatcher()
    }
  }

  function start() {
    // The cache renders immediately; the first scan upgrades itself to a full
    // pass when the cache is missing or belongs to another day.
    requestScan("quick")
    startWatcher()
  }

  function startWatcher() {
    if (!enabled || !watchDatabase || effectiveWatchDir === "") return
    if (watcher.running) return
    watcherRestart.stop()
    watcherStartedAtMs = Date.now()
    watcher.running = true
  }

  function onDatabaseEvent(line) {
    if (String(line || "").trim() === "") return
    if (scanScheduled) return
    var wait = throttleMs - (Date.now() - lastScanAtMs)
    scanDebounce.interval = Math.max(2000, Math.min(throttleMs, wait))
    scanScheduled = true
    scanDebounce.restart()
  }

  // mode: "quick" (today + all-time) or "full" (+ last seven days).
  function requestScan(mode) {
    if (scanner.running) {
      if (mode === "full") pendingMode = "full"
      return
    }
    scanMode = mode === "full" ? "full" : "quick"
    var command = ["nice", "-n", "19", "ionice", "-c", "3", interpreterPath, "-S", scannerPath]
      .concat(scannerArguments || [])
    command.push("--mode", scanMode)
    scanner.command = command
    refreshing = true
    scanner.running = true
  }

  function refresh(force) {
    requestScan(force === true ? "full" : "quick")
  }

  function refreshQuick() {
    requestScan("quick")
  }

  function refreshFull() {
    requestScan("full")
  }

  function refreshLimits() {
    // Called when the panel opens: that is when the seven-day view matters.
    requestScan("full")
  }

  function applyData(data, fromCache) {
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

    var generated = Date.parse(String(data.generatedAt || ""))
    if (isFinite(generated)) lastRefreshedAtMs = generated
    else if (fromCache) lastRefreshedAtMs = 0
  }

  function applyCache(output) {
    if (hasFreshData || scanner.running) return
    var raw = String(output || "").trim()
    if (raw === "") return
    try {
      applyData(JSON.parse(raw), true)
    } catch (e) {
      console.warn("opencode-usage/" + providerId, "Ignoring bad cache:", e)
    }
  }

  function parseScannerOutput(output) {
    var raw = String(output || "").trim()
    if (raw === "") return

    try {
      var data = JSON.parse(raw.split("\n").pop())
      applyData(data, false)
      hasFreshData = true
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

  FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: false
    printErrors: false
    onLoaded: root.applyCache(text())
  }

  Process {
    id: scanner
    running: false

    stdout: StdioCollector {
      onStreamFinished: root.parseScannerOutput(text)
    }

    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") console.warn("opencode-usage/" + root.providerId, text.trim())
    }

    onExited: {
      root.refreshing = false
      root.lastScanAtMs = Date.now()
      if (root.lastRefreshedAtMs === 0) root.lastRefreshedAtMs = root.lastScanAtMs
      if (root.pendingMode !== "") {
        var next = root.pendingMode
        root.pendingMode = ""
        root.requestScan(next)
      }
    }
  }

  // OpenCode writes the WAL while a turn streams; one event is enough to know
  // the database changed, so the debounce timer coalesces the burst.
  Process {
    id: watcher
    running: false

    command: [
      "inotifywait", "-m", "-q",
      "-e", "modify,close_write,create,move",
      "--include", "opencode\\.db(-wal)?$",
      "--format", "%f",
      root.effectiveWatchDir
    ]

    stdout: SplitParser {
      onRead: function(line) { root.onDatabaseEvent(line) }
    }

    onRunningChanged: if (running) root.watcherStartedAtMs = Date.now()

    onExited: {
      if (!root.enabled || !root.watchDatabase) return
      var lived = Date.now() - root.watcherStartedAtMs
      root.watcherFailures = lived < 3000 ? root.watcherFailures + 1 : 0
      if (root.watcherFailures < 3) watcherRestart.restart()
      else console.warn("opencode-usage/" + root.providerId,
        "inotifywait unavailable; falling back to the safety timer")
    }
  }

  Timer {
    id: watcherRestart
    interval: 5000
    repeat: false
    onTriggered: root.startWatcher()
  }

  Timer {
    id: scanDebounce
    interval: 5000
    repeat: false
    onTriggered: {
      root.scanScheduled = false
      root.requestScan("quick")
    }
  }

  Timer {
    id: backgroundTimer
    interval: Math.max(60, Number(root.safetyIntervalSec || 3600)) * 1000
    running: root.enabled
    repeat: true
    onTriggered: {
      // Retry a watcher that gave up earlier, then refresh the numbers even if
      // the watcher is fine (cheap insurance against a missed event).
      if (root.watchDatabase && !watcher.running && root.watcherFailures >= 3) {
        root.watcherFailures = 0
        root.startWatcher()
      }
      root.requestScan("quick")
    }
  }

  Timer {
    interval: root.backgroundRefreshIntervalMs
    running: root.enabled && interval > 0
    repeat: true
    onTriggered: root.requestScan("quick")
  }
}
