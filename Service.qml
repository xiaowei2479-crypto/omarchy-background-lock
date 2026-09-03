import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Background Lock scheduling engine (self-contained; no external scripts).
//
// Responsibilities:
//   - Read the plugin config (day/night theme + wallpaper) and re-apply when
//     it changes (the panel edits it).
//   - Query wttr.in for today's/tomorrow's sunrise & sunset.
//   - On a one-minute timer, compute the current period (day/night) and, when
//     the period flips (sunrise/sunset), apply the matching theme + wallpaper.
//   - Background lock: when the theme changes through any other path (manual
//     `omarchy theme set`, theme switcher, ...), re-apply the period wallpaper.
//   - Write a small state file the bar widget reads to render the pill.
//
// Config:  ~/.local/state/omarchy/settings/background-lock.json
// State:   ~/.local/state/omarchy/sun-theme-state.json
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME") || ""
  // Writable: the shell injects the authoritative OMARCHY_PATH here.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  readonly property string configPath: home + "/.local/state/omarchy/settings/background-lock.json"
  readonly property string statePath: home + "/.local/state/omarchy/sun-theme-state.json"
  readonly property string themeNamePath: home + "/.local/state/omarchy/current/theme.name"
  readonly property string weatherSettingsPath: home + "/.local/state/omarchy/settings/weather.json"

  property var config: Model.parseConfig("", home)
  property var sunTimes: null        // { sunrise, sunset, tomorrowSunrise } in 24h "HH:MM"
  property var schedule: ({})
  property string locationQuery: ""  // wttr.in path segment ("" = IP auto-detect)
  property bool sunFetched: false    // first fetch waits for the weather location
  property string lastAppliedPeriod: ""
  property bool applyingOwn: false

  Component.onCompleted: {
    // Apply immediately with sane defaults; sun times are refined from wttr.in
    // once the weather location is known (see onWeather / onWeatherFailed).
    if (!root.sunTimes) root.sunTimes = { sunrise: "06:00", sunset: "18:00", tomorrowSunrise: "06:00" }
    tick(true)
    minuteTimer.start()
    rescanTimer.start()
  }

  function nowEpoch() { return Math.floor(Date.now() / 1000) }

  // ---- config -------------------------------------------------------------
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.onConfig(configFile.text())
    onLoadFailed: root.onConfig("")
    onFileChanged: reload()
  }

  function onConfig(text) {
    root.config = Model.parseConfig(text, root.home)
    tick(true)  // config changed: re-apply the current period
  }

  // ---- optional location (shared with the weather widget) ------------------
  FileView {
    id: weatherFile
    path: root.weatherSettingsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.onWeather(weatherFile.text())
    onLoadFailed: root.onWeather("")
    onFileChanged: reload()
  }

  function onWeather(text) {
    var w = Model.parseState(text)
    var name = String(w.name || "").trim()
    var query = name ? encodeURIComponent(name) : ""
    var changed = query !== root.locationQuery
    root.locationQuery = query
    // Fetch on first location resolution (so the first query already uses the
    // configured place instead of IP auto-detect) and whenever it changes.
    if (changed || !root.sunFetched) {
      root.sunFetched = true
      fetchSun()
    }
  }

  // ---- sun times (wttr.in) -------------------------------------------------
  // If a fetch is requested while one is in flight (e.g. the configured
  // location arrives right after startup's IP-based fetch), queue a refetch
  // with the latest location instead of dropping it.
  property bool sunFetchPending: false

  function fetchSun() {
    if (sunProc.running) { root.sunFetchPending = true; return }
    sunProc.command = ["curl", "-fsS", "--max-time", "8", "https://wttr.in/" + root.locationQuery + "?format=j1"]
    sunProc.running = true
  }

  Process {
    id: sunProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseWttr(text)
        if (parsed) {
          root.sunTimes = parsed
          root.sunRetries = 0
        } else if (!root.sunTimes) {
          root.sunTimes = { sunrise: "06:00", sunset: "18:00", tomorrowSunrise: "06:00" }
        }
        root.tick(false)
        // A newer location arrived mid-flight — refetch with it.
        if (root.sunFetchPending) {
          root.sunFetchPending = false
          root.fetchSun()
          return
        }
        // Keep stale defaults only briefly: retry failed fetches a few times.
        if (!parsed) root.scheduleSunRetry()
      }
    }
  }

  property int sunRetries: 0

  function scheduleSunRetry() {
    if (root.sunRetries >= 4) return
    root.sunRetries++
    sunRetryTimer.restart()
  }

  Timer {
    id: sunRetryTimer
    interval: 10000
    onTriggered: root.fetchSun()
  }

  // ---- scheduling tick ------------------------------------------------------
  // forceApply re-applies the current period even when it did not change
  // (used after a config edit). Otherwise we only apply on a period flip.
  function tick(forceApply) {
    if (!root.sunTimes) return
    var s = Model.computeSchedule(root.sunTimes, root.config, nowEpoch())
    var changed = s.period !== root.lastAppliedPeriod
    root.schedule = s
    writeState(s)
    if (forceApply || changed) {
      root.lastAppliedPeriod = s.period
      applyPeriod(s)
    }
  }

  Timer {
    id: minuteTimer
    interval: 60000
    repeat: true
    onTriggered: root.tick(false)
  }

  // Refresh sun times every few hours (and across day rollovers).
  Timer {
    id: rescanTimer
    interval: 6 * 3600 * 1000
    repeat: true
    onTriggered: root.fetchSun()
  }

  // ---- apply theme + wallpaper ----------------------------------------------
  property string pendingTheme: ""
  property string pendingWallpaper: ""

  function applyPeriod(s) {
    if (!s || !s.current_theme) return
    root.pendingTheme = s.current_theme
    root.pendingWallpaper = s.period === "night" ? s.night_wallpaper : s.day_wallpaper
    if (!currentThemeProc.running) currentThemeProc.running = true
  }

  Process {
    id: currentThemeProc
    command: ["omarchy", "theme", "current"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var cur = String(text || "").trim()
        if (root.pendingTheme !== "" && cur !== root.pendingTheme) {
          root.applyingOwn = true
          themeSetProc.command = ["omarchy", "theme", "set", root.pendingTheme]
          themeSetProc.running = true
        } else {
          root.applyWallpaper()
        }
      }
    }
  }

  Process {
    id: themeSetProc
    onExited: function(code) { root.applyWallpaper() }
  }

  function applyWallpaper() {
    if (root.pendingWallpaper === "") { root.applyingOwn = false; return }
    if (bgSetProc.running) return
    bgSetProc.command = ["omarchy", "theme", "bg", "set", root.pendingWallpaper]
    bgSetProc.running = true
  }

  Process {
    id: bgSetProc
    onExited: function(code) {
      root.applyingOwn = false
      root.tick(false)  // refresh state after applying
    }
  }

  // ---- background lock -------------------------------------------------------
  // Re-apply the period wallpaper when the theme changes outside the scheduler.
  FileView {
    id: themeNameFile
    path: root.themeNamePath
    watchChanges: true
    printErrors: false
    onFileChanged: root.onExternalThemeSwitch()
  }

  function onExternalThemeSwitch() {
    if (root.applyingOwn) return
    lockDebounce.restart()
  }

  Timer {
    id: lockDebounce
    interval: 1200
    onTriggered: {
      var wallpaper = root.schedule.period === "night" ? root.schedule.night_wallpaper : root.schedule.day_wallpaper
      if (wallpaper === "") return
      if (bgSetProc.running) return
      bgSetProc.command = ["omarchy", "theme", "bg", "set", wallpaper]
      bgSetProc.running = true
    }
  }

  // ---- state file for the bar widget ----------------------------------------
  // Debounced + queued: rapid successive updates collapse to the newest value,
  // and a busy writer re-runs once it exits so the latest state always lands.
  property string pendingStateJson: ""

  function writeState(s) {
    root.pendingStateJson = Model.buildState(s)
    stateWriteTimer.restart()
  }

  Timer {
    id: stateWriteTimer
    interval: 250
    onTriggered: root.flushState()
  }

  function flushState() {
    if (stateWriter.running) { stateWriteTimer.restart(); return }
    stateWriter.content = root.pendingStateJson
    stateWriter.running = true
  }

  // Generic stdin file writer: streams `content` into the state file.
  Process {
    id: stateWriter
    property string content: ""
    command: ["sh", "-c", "mkdir -p \"$(dirname \"$1\")\" && cat > \"$1\"", "sh", root.statePath]
    stdinEnabled: true
    onStarted: {
      write(stateWriter.content)
      stdinEnabled = false  // close the pipe -> EOF -> file written
    }
    onExited: function(code) {
      if (stateWriter.content !== root.pendingStateJson) root.stateWriteTimer.restart()
    }
  }
}
