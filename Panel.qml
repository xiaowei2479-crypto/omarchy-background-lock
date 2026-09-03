import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Popup panel for the Background Lock plugin (self-contained).
// Reads/writes the plugin config directly, lists themes/wallpapers by scanning
// the theme directories, and applies manual day/night switches via omarchy —
// no external helper scripts.

Panel {
  id: root
  moduleName: "xiaowei2479.background-lock"
  ipcTarget: "xiaowei2479.background-lock"

  property var anchorItem: null
  property var hostWidget: null
  property bool openedFromHotkey: false
  property var scheduleSource: null

  readonly property var schedule: scheduleSource ? scheduleSource.schedule : ({})
  property string dayWallpaperPath: ""
  property string nightWallpaperPath: ""
  readonly property string home: Quickshell.env("HOME") || ""
  // Writable: the shell injects the authoritative OMARCHY_PATH here.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy"
  readonly property string configPath: home + "/.local/state/omarchy/settings/background-lock.json"

  readonly property var barIdentity: hostWidget || root

  // Config + catalog data
  property var config: Model.parseConfig("", home)
  property var themeCatalog: []      // [{slug, name}]
  property var dayWallpaperCatalog: []
  property var nightWallpaperCatalog: []

  function open() {
    openedFromHotkey = false
    root.controller.show()
    Qt.callLater(refreshAll)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    Qt.callLater(refreshAll)
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // ---- config (watch so external edits and our own saves both refresh) ----

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.onConfigLoaded(configFile.text())
    onLoadFailed: root.onConfigLoaded("")
    onFileChanged: reload()
  }

  function onConfigLoaded(text) {
    var prevDaySlug = Model.nameToSlug(root.config.day_theme)
    var prevNightSlug = Model.nameToSlug(root.config.night_theme)
    root.config = Model.parseConfig(text, root.home)
    if (Model.nameToSlug(root.config.day_theme) !== prevDaySlug) loadDayWallpapers()
    if (Model.nameToSlug(root.config.night_theme) !== prevNightSlug) loadNightWallpapers()
  }

  // ---- data loading -------------------------------------------------------

  function refreshAll() {
    configFile.reload()
    loadThemes()
    loadDayWallpapers()
    loadNightWallpapers()
  }

  function loadThemes() {
    var dirs = root.home + "/.config/omarchy/themes " + root.omarchyPath + "/themes"
    themeProc.command = ["sh", "-c", 'find ' + dirs + ' -mindepth 1 -maxdepth 1 \\( -type d -o -type l \\) -printf "%f\\n" 2>/dev/null | sort -u']
    if (!themeProc.running) themeProc.running = true
  }

  function loadDayWallpapers() {
    dayWallProc.command = ["sh", "-c", wallpaperFindCmd(Model.nameToSlug(root.config.day_theme))]
    if (!dayWallProc.running) dayWallProc.running = true
  }

  function loadNightWallpapers() {
    nightWallProc.command = ["sh", "-c", wallpaperFindCmd(Model.nameToSlug(root.config.night_theme))]
    if (!nightWallProc.running) nightWallProc.running = true
  }

  function wallpaperFindCmd(slug) {
    var dirs = root.home + "/.config/omarchy/backgrounds/" + slug + " " + root.omarchyPath + "/themes/" + slug + "/backgrounds"
    return 'find ' + dirs + ' -maxdepth 1 -type f \\( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.webp" -o -iname "*.gif" \\) 2>/dev/null | sort -u'
  }

  function onThemesLoaded(text) {
    root.themeCatalog = Model.parseThemeList(text)
  }

  function onDayWallpapersLoaded(text) {
    root.dayWallpaperCatalog = Model.parsePathList(text)
  }
  function onNightWallpapersLoaded(text) {
    root.nightWallpaperCatalog = Model.parsePathList(text)
  }

  // Wallpaper option list for a dropdown: empty string means "theme default"
  function wallpaperOptions(catalog) {
    var opts = [{ value: "", label: "（主题默认）" }]
    for (var i = 0; i < (catalog || []).length; i++) {
      var p = catalog[i]
      opts.push({ value: p, label: Model.wallpaperLabel(p) })
    }
    return opts
  }

  // ---- config actions -----------------------------------------------------

  function updateConfig(mutator) {
    var c = {
      day_theme: root.config.day_theme,
      night_theme: root.config.night_theme,
      day_wallpaper: root.config.day_wallpaper,
      night_wallpaper: root.config.night_wallpaper
    }
    mutator(c)
    configWriter.content = Model.buildConfig(c)
    if (!configWriter.running) configWriter.running = true
    // FileView watchChanges reloads the config (and the service re-applies).
  }

  function saveDayTheme(name) {
    updateConfig(function(c) { c.day_theme = name })
  }
  function saveNightTheme(name) {
    updateConfig(function(c) { c.night_theme = name })
  }
  function saveDayWallpaper(path) {
    updateConfig(function(c) { c.day_wallpaper = path })
  }
  function saveNightWallpaper(path) {
    updateConfig(function(c) { c.night_wallpaper = path })
  }

  // ---- manual switch --------------------------------------------------------
  // Hands a request to the service (via a small file), which applies it as a
  // temporary override — theme, wallpaper, and background lock all move
  // together — and resumes the schedule at the next sunrise/sunset boundary.
  readonly property string manualRequestPath: home + "/.local/state/omarchy/background-lock-manual.json"

  function manualDay() { applyManual("day") }
  function manualNight() { applyManual("night") }

  function applyManual(period) {
    manualReqWriter.content = '{"period":"' + period + '","ts":' + Math.floor(Date.now() / 1000) + '}'
    if (!manualReqWriter.running) manualReqWriter.running = true
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    // 高度自适应内容（fittedContentHeight = 内容高 + 边距，超屏才滚动）
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: column.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: column.implicitHeight > scrollArea.height
        }


        Column {
          id: column
          width: scrollArea.availableWidth

          leftPadding: 0
          rightPadding: 0
          topPadding: Style.space(12)
          bottomPadding: Style.space(12)
          spacing: Style.space(10)

          // ---- Hero: icon + title + status ----
          PanelHero {
            title: "Background Lock"
            meta: (root.schedule.period === "night" ? "🌙 夜晚" : "☀ 白天") + " · " + (root.schedule.current_theme || "")
            detail: root.schedule.next_epoch ? ("下次切换 " + Model.epochToTime(root.schedule.next_epoch)) : ""
            foreground: root.bar ? root.bar.foreground : Color.foreground
          }

          PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

          // ---- Day config ----
          PanelSectionHeader {
            text: "白天"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Dropdown {
            width: parent.width
            label: "白天主题"
            fontFamily: Style.font.family
            options: root.themeCatalog.map(function(t) { return { value: t.slug, label: t.name } })
            value: root.config.day_theme ? slugOf(root.config.day_theme) : ""
            onChanged: function(v) {
              var name = nameOf(v)
              if (name) root.saveDayTheme(name)
            }
          }

          Dropdown {
            width: parent.width
            label: "白天壁纸"
            fontFamily: Style.font.family
            options: root.wallpaperOptions(root.dayWallpaperCatalog)
            value: root.config.day_wallpaper || ""
            onChanged: function(v) { root.saveDayWallpaper(v) }
          }

          WallpaperPreview {
            source: root.config.day_wallpaper || root.dayWallpaperPath
            label: "白天壁纸"
            fg: root.bar ? root.bar.foreground : Color.foreground
            width: parent.width
          }

          PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

          // ---- Night config ----
          PanelSectionHeader {
            text: "夜晚"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Dropdown {
            width: parent.width
            label: "夜晚主题"
            fontFamily: Style.font.family
            options: root.themeCatalog.map(function(t) { return { value: t.slug, label: t.name } })
            value: root.config.night_theme ? slugOf(root.config.night_theme) : ""
            onChanged: function(v) {
              var name = nameOf(v)
              if (name) root.saveNightTheme(name)
            }
          }

          Dropdown {
            width: parent.width
            label: "夜晚壁纸"
            fontFamily: Style.font.family
            options: root.wallpaperOptions(root.nightWallpaperCatalog)
            value: root.config.night_wallpaper || ""
            onChanged: function(v) { root.saveNightWallpaper(v) }
          }

          WallpaperPreview {
            source: root.config.night_wallpaper || root.nightWallpaperPath
            label: "夜晚壁纸"
            fg: root.bar ? root.bar.foreground : Color.foreground
            width: parent.width
          }

          PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

          // ---- Manual switch ----
          PanelSectionHeader {
            text: "手动切换"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Row {
            spacing: Style.space(8)
            width: parent.width
            Button {
              text: "☀ 白天"
              width: (parent.width - Style.space(8)) / 2
              onClicked: root.manualDay()
            }
            Button {
              text: "🌙 夜晚"
              width: (parent.width - Style.space(8)) / 2
              onClicked: root.manualNight()
            }
          }

          Text {
            text: "手动切换后，日出/日落仍会自动切回"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted
          }

          PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }

          // ---- Schedule info ----
          PanelSectionHeader {
            text: "切换依据"
            foreground: root.bar ? root.bar.foreground : Color.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Grid {
            columns: 2
            columnSpacing: Style.space(16)
            rowSpacing: Style.space(4)
            width: parent.width

            Text { text: "日出"; font.family: Style.font.family; font.pixelSize: Style.font.caption; color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted }
            Text { text: Model.hour12(root.schedule.sunrise); font.family: Style.font.family; font.pixelSize: Style.font.caption; color: root.bar ? root.bar.foreground : Color.foreground }

            Text { text: "日落"; font.family: Style.font.family; font.pixelSize: Style.font.caption; color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted }
            Text { text: Model.hour12(root.schedule.sunset); font.family: Style.font.family; font.pixelSize: Style.font.caption; color: root.bar ? root.bar.foreground : Color.foreground }

            Text { text: "明日日出"; font.family: Style.font.family; font.pixelSize: Style.font.caption; color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted }
            Text { text: Model.hour12(root.schedule.tomorrow_sunrise); font.family: Style.font.family; font.pixelSize: Style.font.caption; color: root.bar ? root.bar.foreground : Color.foreground }
          }

          Text {
            text: root.schedule.updated ? ("更新于 " + new Date(root.schedule.updated * 1000).toLocaleString()) : ""
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: root.bar ? Qt.darker(root.bar.foreground, 1.4) : Color.muted
          }
        }
      }
    }
  }



  // slug helpers
  function slugOf(displayName) {
    return Model.nameToSlug(displayName)
  }
  function nameOf(slug) {
    for (var i = 0; i < root.themeCatalog.length; i++) {
      if (root.themeCatalog[i].slug === slug) return root.themeCatalog[i].name
    }
    return ""
  }

  // ---- background processes ----------------------------------------------

  Process {
    id: themeProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.onThemesLoaded(text) }
  }
  Process {
    id: dayWallProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.onDayWallpapersLoaded(text) }
  }
  Process {
    id: nightWallProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.onNightWallpapersLoaded(text) }
  }

  // Writes the config file via argv (no stdin pipe to close); the FileView
  // watch reloads it afterwards.
  Process {
    id: configWriter
    property string content: ""
    command: ["sh", "-c", "mkdir -p \"$(dirname \"$2\")\" && printf %s \"$1\" > \"$2\"", "w", configWriter.content, root.configPath]
    onExited: function(code) { configFile.reload() }
  }

  // Writes the manual-switch request file; the service watches it and applies.
  Process {
    id: manualReqWriter
    property string content: ""
    command: ["sh", "-c", "mkdir -p \"$(dirname \"$2\")\" && printf %s \"$1\" > \"$2\"", "w", manualReqWriter.content, root.manualRequestPath]
  }
}
