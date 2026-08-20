import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "Model.js" as Model

// Watches MPRIS for the current track and keeps one matching Ultimate Guitar
// tab loaded for it. Lives in the service plugin so a lookup happens once per
// song no matter how many monitors show the bar widget.
Item {
  id: root

  // Pushed in by the bar widget, which owns the user-facing settings.
  property string preferredType: "tabs"

  // Raised by IPC so a keybind can drive the panel the widget owns.
  signal toggleRequested()
  signal openRequested()
  signal closeRequested()

  // Mirrored back by the widget so `status` reports whether the panel is up.
  property bool panelOpen: false

  // The helper ships next to this file, so the plugin works the same whether
  // it was installed by `omarchy plugin add` or symlinked from a checkout.
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("bin/ug-tabs"))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }
  // Called explicitly rather than through the shebang: the shell inherits a
  // PATH where `python3` may be a version manager's shim.
  readonly property string python: "/usr/bin/python3"

  // --- what is playing -----------------------------------------------------

  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var activePlayer: chooseActivePlayer()
  readonly property bool hasMedia: activePlayer !== null && title !== ""
  readonly property string title: activePlayer ? String(activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? String(activePlayer.trackArtist || "") : ""
  readonly property string trackKey: hasMedia ? artist + " " + title : ""
  readonly property string nowPlaying: {
    if (!hasMedia) return ""
    return artist ? artist + "  " + title : title
  }

  function isProxy(player) {
    if (!player) return false
    var dbus = String(player.dbusName || "").toLowerCase()
    return dbus.indexOf("playerctld") !== -1
      || String(player.desktopEntry || "").toLowerCase() === "playerctld"
  }

  function isCandidate(player) {
    return !!(player && player.playbackState !== MprisPlaybackState.Stopped && player.trackTitle)
  }

  function chooseActivePlayer() {
    var fallback = null
    for (var i = 0; i < players.length; i++) {
      var player = players[i]
      if (!isCandidate(player)) continue
      if (player.isPlaying && !isProxy(player)) return player
      if (!fallback) fallback = player
    }
    return fallback
  }

  // --- lookup state --------------------------------------------------------

  // idle | searching | loading | ready | empty | error
  property string lookupState: "idle"
  property var tab: null
  property var versions: []
  property string errorText: ""

  readonly property bool busy: lookupState === "searching" || lookupState === "loading"
  readonly property string tabUrl: tab ? String(tab.url || "") : ""
  readonly property string officialUrl: tab && tab.official ? String(tab.official.url || "") : ""
  readonly property bool hasOfficial: officialUrl !== ""
  readonly property string searchUrl: hasMedia ? Model.searchPageUrl(artist, title) : ""

  // Every lookup carries the serial it started under; a track change bumps the
  // serial so results for the previous song are dropped instead of flashing up.
  property int serial: 0
  property int searchSerial: -1
  property int tabSerial: -1
  property var pendingQueries: []
  property bool bypassCache: false

  onTrackKeyChanged: {
    serial++
    tab = null
    versions = []
    errorText = ""
    debounce.stop()
    if (!hasMedia) {
      lookupState = "idle"
      return
    }
    lookupState = "searching"
    debounce.restart()
  }

  // Changing the preferred type in bar settings re-picks for the current song
  // rather than waiting for the next one.
  onPreferredTypeChanged: if (hasMedia) startLookup()

  // Skipping through a playlist should cost one lookup, not one per track.
  Timer {
    id: debounce
    interval: 900
    onTriggered: root.startLookup()
  }

  function startLookup() {
    if (!hasMedia) {
      lookupState = "idle"
      return
    }
    serial++
    errorText = ""
    lookupState = "searching"
    pendingQueries = Model.searchQueries(artist, title)
    nextSearch()
  }

  function refresh() {
    if (!hasMedia) return
    bypassCache = true
    startLookup()
  }

  function helperCommand(args) {
    var command = [python, helperPath]
    if (bypassCache) command.push("--no-cache")
    return command.concat(args)
  }

  function nextSearch() {
    if (!pendingQueries.length) {
      lookupState = "empty"
      return
    }
    var query = pendingQueries[0]
    pendingQueries = pendingQueries.slice(1)
    searchSerial = serial
    searchProc.running = false
    searchProc.command = helperCommand(["search", query])
    Qt.callLater(function () { searchProc.running = true })
  }

  function loadTab(url) {
    if (!url) return
    tabSerial = serial
    lookupState = "loading"
    tabProc.running = false
    tabProc.command = helperCommand(["tab", String(url)])
    Qt.callLater(function () { tabProc.running = true })
  }

  function parsePayload(raw) {
    var text = String(raw || "").trim()
    if (!text) return null
    try {
      return JSON.parse(text)
    } catch (error) {
      return null
    }
  }

  function fail(message) {
    errorText = String(message || "Something went wrong")
    lookupState = "error"
  }

  function handleSearch(raw) {
    if (searchSerial !== serial) return
    var payload = parsePayload(raw)
    if (!payload) {
      fail("Could not run the tab fetcher. Is " + python + " present?")
      return
    }
    if (!payload.ok) {
      fail(payload.error)
      return
    }
    var best = Model.pickBest(payload.results, artist, title, preferredType)
    if (!best) {
      // The tidied query found nothing; the verbatim one may still land.
      if (pendingQueries.length) nextSearch()
      else lookupState = "empty"
      return
    }
    loadTab(best.url)
  }

  function handleTab(raw) {
    if (tabSerial !== serial) return
    bypassCache = false
    var payload = parsePayload(raw)
    if (!payload) {
      fail("Could not run the tab fetcher. Is " + python + " present?")
      return
    }
    if (!payload.ok) {
      fail(payload.error)
      return
    }
    tab = payload.tab
    versions = Model.renderableVersions(payload.tab ? payload.tab.versions : [], preferredType)
    lookupState = tab && tab.content ? "ready" : "empty"
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleSearch(text)
    }
  }

  Process {
    id: tabProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleTab(text)
    }
  }

  // --- opening pages -------------------------------------------------------

  function openUrl(url) {
    if (!url) return false
    Quickshell.execDetached(["omarchy-launch-browser", String(url)])
    return true
  }

  // Official tabs are Guitar Pro-style binaries played by Ultimate Guitar's own
  // web player, so they open in the browser, where the user's Pro session lives.
  function openOfficial() { return openUrl(officialUrl) }
  function openCurrent() { return openUrl(tabUrl) }
  function openSearch() { return openUrl(searchUrl) }

  function statusObject() {
    return {
      playing: hasMedia,
      artist: artist,
      title: title,
      state: lookupState,
      panelOpen: panelOpen,
      url: tabUrl,
      official: officialUrl,
      type: tab ? String(tab.type || "") : "",
      versions: versions.length,
      error: errorText
    }
  }

  IpcHandler {
    target: "crmne.ultimate-guitar"

    function status(): string {
      return JSON.stringify(root.statusObject())
    }

    function refresh(): string {
      root.refresh()
      return "ok"
    }

    function toggle(): string {
      root.toggleRequested()
      return "ok"
    }

    function show(): string {
      root.openRequested()
      return "ok"
    }

    function hide(): string {
      root.closeRequested()
      return "ok"
    }

    function open(): string {
      return root.openCurrent() ? "ok" : "unhandled"
    }

    function official(): string {
      return root.openOfficial() ? "ok" : "unhandled"
    }
  }
}
