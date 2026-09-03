import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget for the Background Lock plugin: a sun/moon pill that opens a
// panel with the sunrise/sunset theme schedule and the locked background.
//
// The widget shows which period is active (day/night) and, on click, opens
// a panel detailing:
//   - the switching basis: today's sunrise & sunset times
//   - which theme is used during the day and which during the night
//   - a preview of the locked background image

BarWidget {
  id: root
  moduleName: "xiaowei2479.background-lock"

  property var shell: null
  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string statePath: home + "/.local/state/omarchy/sun-theme-state.json"
  readonly property string dayWallpaperPath: home + "/.config/omarchy/backgrounds/day.png"
  readonly property string nightWallpaperPath: home + "/.config/omarchy/backgrounds/night.png"

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // Loaded state from sun-theme-state.json (written by this plugin's Service.qml)
  property var schedule: ({})

  // Panel behaviour (mirrors the weather widget's wiring)
  readonly property bool opened: panel.item ? panel.item.opened === true : false

  function open() {
    if (panel.item && panel.item.openFromHotkey) panel.item.openFromHotkey()
  }
  function close() {
    if (panel.item && panel.item.close) panel.item.close()
  }
  function togglePanel() {
    if (panel.item && panel.item.toggle) panel.item.toggle()
  }
  readonly property bool popoutSwitchClosing: panel.item ? panel.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() {
    if (panel.item) panel.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panel.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("scheduleSource" in target) target.scheduleSource = root
    if ("dayWallpaperPath" in target) target.dayWallpaperPath = root.dayWallpaperPath
    if ("nightWallpaperPath" in target) target.nightWallpaperPath = root.nightWallpaperPath
  }

  // Read the schedule JSON when the panel opens and on a timer so the pill
  // stays fresh after sunrise/sunset switches.
  function refresh() {
    stateFile.reload()
  }

  Timer {
    interval: 60000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.schedule = Model.parseState(text())
    onFileChanged: reload()
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Loader {
    id: panel
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Sun by day, moon by night; falls back to a sparkle when unknown.
    text: root.schedule.period === "night" ? "" : (root.schedule.period === "day" ? "" : "")
    slotSize: Style.bar.statusSlot
    tooltipText: root.schedule.current_theme ? ("当前: " + root.schedule.current_theme) : ""

    onPressed: function(b) {
      if (b === Qt.LeftButton) root.togglePanel()
    }
  }
}
