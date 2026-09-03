// Data helpers for the Background Lock plugin. Pure functions only — no
// Quickshell types — so they can be unit-tested and shared between the
// service (scheduling engine) and the panel (config UI).

// ---------------------------------------------------------------------------
// Generic JSON
// ---------------------------------------------------------------------------

// Parse a JSON string; {} on failure.
function parseState(text) {
  try {
    var parsed = JSON.parse(String(text || ""))
    if (parsed && typeof parsed === "object") return parsed
  } catch (e) {
    // fall through
  }
  return {}
}

// ---------------------------------------------------------------------------
// Theme slug <-> display name
// ---------------------------------------------------------------------------

// "rose-pine" -> "Rose Pine"
function slugToName(slug) {
  return String(slug || "")
    .split("-")
    .map(function(part) { return part ? part.charAt(0).toUpperCase() + part.slice(1) : part })
    .join(" ")
}

// "Rose Pine" -> "rose-pine"
function nameToSlug(name) {
  return String(name || "").trim().toLowerCase().replace(/\s+/g, "-")
}

// ---------------------------------------------------------------------------
// Config (~/.local/state/omarchy/settings/background-lock.json)
// ---------------------------------------------------------------------------

function defaultConfig(home) {
  return {
    day_theme: "Rose Pine",
    night_theme: "Tokyo Night",
    day_wallpaper: home + "/.config/omarchy/backgrounds/day.png",
    night_wallpaper: home + "/.config/omarchy/backgrounds/night.png"
  }
}

// Parse config JSON, filling defaults for any missing/empty field.
function parseConfig(text, home) {
  var d = defaultConfig(home)
  var c = parseState(text)
  return {
    day_theme: String(c.day_theme || "").trim() || d.day_theme,
    night_theme: String(c.night_theme || "").trim() || d.night_theme,
    day_wallpaper: String(c.day_wallpaper || "").trim() || d.day_wallpaper,
    night_wallpaper: String(c.night_wallpaper || "").trim() || d.night_wallpaper
  }
}

// Serialize a config object to a pretty JSON string for writing to disk.
function buildConfig(config) {
  return JSON.stringify({
    day_theme: String(config.day_theme || ""),
    night_theme: String(config.night_theme || ""),
    day_wallpaper: String(config.day_wallpaper || ""),
    night_wallpaper: String(config.night_wallpaper || "")
  }, null, 2) + "\n"
}

// ---------------------------------------------------------------------------
// Time helpers
// ---------------------------------------------------------------------------

// "05:42 AM" -> "05:42" (12h -> 24h "HH:MM")
function hour12(hhmmAP) {
  var m = /^(\d{1,2}):(\d{2})\s*(AM|PM)$/i.exec(String(hhmmAP || "").trim())
  if (!m) return String(hhmmAP || "")
  var h = parseInt(m[1], 10)
  var ap = m[3].toUpperCase()
  if (ap === "PM" && h < 12) h += 12
  if (ap === "AM" && h === 12) h = 0
  return pad2(h) + ":" + m[2]
}

function pad2(n) {
  n = parseInt(n, 10)
  return (n < 10 ? "0" : "") + n
}

// Epoch seconds -> "HH:MM" local time
function epochToTime(epoch) {
  if (!epoch) return ""
  var d = new Date(epoch * 1000)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// "HH:MM" (24h) -> epoch seconds for that time today (local).
function epochToday(hhmm24) {
  var m = /^(\d{1,2}):(\d{2})$/.exec(String(hhmm24 || "").trim())
  if (!m) return 0
  var d = new Date()
  d.setHours(parseInt(m[1], 10), parseInt(m[2], 10), 0, 0)
  return Math.floor(d.getTime() / 1000)
}

// "HH:MM" (24h) -> epoch seconds for that time tomorrow (local).
// Mirrors the bash scheduler's "+86400" approximation across DST boundaries.
function epochTomorrow(hhmm24) {
  return epochToday(hhmm24) + 86400
}

// Basename without extension, humanized ("3-omarchy-plants.png" -> "3. omarchy plants")
function wallpaperLabel(path) {
  var base = String(path || "").split("/").pop()
  base = base.replace(/\.[^.]+$/, "")
  base = base.replace(/^(\d+)-/, "$1. ")
  base = base.replace(/[-_]/g, " ")
  return base
}

// ---------------------------------------------------------------------------
// wttr.in parsing
// ---------------------------------------------------------------------------

// Parse wttr.in ?format=j1 -> { sunrise, sunset, tomorrowSunrise } in 24h
// "HH:MM", or null when the payload does not carry two days of astronomy.
function parseWttr(text) {
  var data = parseState(text)
  var weather = data.weather
  if (!weather || !weather.length) return null
  function astro(i) {
    var w = weather[i]
    if (!w || !w.astronomy || !w.astronomy.length) return null
    return w.astronomy[0]
  }
  var today = astro(0)
  var tomorrow = astro(1) || today
  if (!today || !today.sunrise || !today.sunset) return null
  return {
    sunrise: hour12(today.sunrise),
    sunset: hour12(today.sunset),
    tomorrowSunrise: hour12(tomorrow && tomorrow.sunrise ? tomorrow.sunrise : today.sunrise)
  }
}

// ---------------------------------------------------------------------------
// Schedule computation
// ---------------------------------------------------------------------------

// Compute the current schedule from sun times + config.
//   sun:    { sunrise, sunset, tomorrowSunrise }  (24h "HH:MM")
//   config: { day_theme, night_theme, day_wallpaper, night_wallpaper }
//   nowEpoch: seconds
// Returns a state object matching what the bar widget / panel display.
function computeSchedule(sun, config, nowEpoch) {
  var tsSr = epochToday(sun.sunrise)
  var tsSs = epochToday(sun.sunset)
  var tmSr = epochTomorrow(sun.tomorrowSunrise)

  var period, theme, nextEpoch, label
  if (nowEpoch >= tsSr && nowEpoch < tsSs) {
    period = "day"
    theme = config.day_theme
    nextEpoch = tsSs
    label = "日落切换"
  } else {
    period = "night"
    theme = config.night_theme
    if (nowEpoch < tsSr) {
      nextEpoch = tsSr
      label = "日出切换"
    } else {
      nextEpoch = tmSr
      label = "日出切换"
    }
  }

  return {
    sunrise: sun.sunrise,
    sunset: sun.sunset,
    tomorrow_sunrise: sun.tomorrowSunrise,
    day_theme: config.day_theme,
    night_theme: config.night_theme,
    period: period,
    current_theme: theme,
    next_label: label,
    next_epoch: nextEpoch,
    updated: nowEpoch,
    day_wallpaper: config.day_wallpaper,
    night_wallpaper: config.night_wallpaper
  }
}

// Serialize a schedule/state object for the bar widget's state file.
function buildState(schedule) {
  return JSON.stringify(schedule) + "\n"
}

// ---------------------------------------------------------------------------
// Directory listing parsers (Process find output)
// ---------------------------------------------------------------------------

// Parse newline-separated `find ... -printf '%f\n'` output into a sorted,
// de-duplicated [{slug, name}] theme catalog.
function parseThemeList(text) {
  var seen = {}
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var slug = String(lines[i] || "").trim()
    if (!slug || seen[slug]) continue
    seen[slug] = true
    out.push({ slug: slug, name: slugToName(slug) })
  }
  out.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) })
  return out
}

// Parse newline-separated `find ... -type f` output into a sorted, de-duped
// array of wallpaper paths.
function parsePathList(text) {
  var seen = {}
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var p = String(lines[i] || "").trim()
    if (!p || seen[p]) continue
    seen[p] = true
    out.push(p)
  }
  out.sort()
  return out
}
