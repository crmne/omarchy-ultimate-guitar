// Isolated screenshot host. Production plugin QML and theme, invented track.
// The copied Service has its MPRIS source and helper runs removed (see
// capture.py); a fixture player and tab are fed through its real handlers.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons

ShellRoot {
  id: host
  property var fixtures: null
  Component.onCompleted: Style.cornerRadius = 10
  FileView {
    path: Quickshell.env("UG_CAPTURE_FIXTURES")
    onLoaded: host.fixtures = JSON.parse(text())
  }
  readonly property string plugin: "file://" + Quickshell.env("UG_CAPTURE_PLUGIN")
  Loader { id: service; source: host.plugin + "/Service.qml" }
  Loader { id: probe; source: host.plugin + "/Probe.qml" }
  QtObject {
    id: bar
    property string position: "top"
    property real barSize: 26
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property color urgent: Color.urgent
    property color barForeground: Color.bar.text
    property color foreground: Color.bar.text
    property color background: Color.bar.background
    property string fontFamily: Style.font.family
    property var activePopout: null
    property var shell: QtObject { function serviceFor(name) { return service.item } }
    function requestPopout(key) { activePopout = key }
    function releasePopout(key) { if (activePopout === key) activePopout = null }
    function showTooltip(item, text) {}
    function hideTooltip(item) {}
  }
  FloatingWindow {
    implicitWidth: 1400; implicitHeight: 30
    color: "transparent"
    Loader {
      id: widget
      x: 1100; y: 2
      active: !!service.item
      source: host.plugin + "/BarWidget.qml"
      onLoaded: {
        item.bar = bar
        item.settings = { hideWhenIdle: false, panelWidthPercent: 50, panelHeightPercent: 100 }
      }
    }
  }

  function popup() {
    var data = widget.item ? widget.item.data : []
    for (var i = 0; i < data.length; i++) {
      if (data[i] && data[i].captureCard !== undefined) return data[i]
    }
    return null
  }
  function reader() { var p = popup(); return p ? p.captureContent : null }
  function pickers() {
    var r = reader()
    var found = {}
    function walk(item) {
      if (!item) return
      if (item.label === "Version" && item.options !== undefined) found.version = item
      if (item.label === "Instrument" && item.options !== undefined) found.instrument = item
      for (var i = 0; i < item.children.length; i++) walk(item.children[i])
    }
    walk(r)
    return found
  }

  // The dropdown's list lives in the window's popup layer, outside the card,
  // so it is grabbed on its own and put back at the offset it was drawn at.
  function dropdownPopup(dropdown) {
    var found = null
    function walk(object) {
      if (!object || found) return
      if (object.opened !== undefined && object.contentItem !== undefined && object.background !== undefined) {
        found = object
        return
      }
      var data = object.data
      if (!data) return
      for (var i = 0; i < data.length; i++) walk(data[i])
    }
    walk(dropdown)
    return found
  }
  property var instrumentsOffset: ({ x: 0, y: 0, width: 0, height: 0 })

  FloatingWindow {
    id: assembly
    implicitWidth: Math.max(1, host.instrumentsOffset.width)
    implicitHeight: Math.max(1, host.instrumentsOffset.height)
    visible: false
    color: "transparent"
    Item {
      id: instrumentsShot
      width: host.instrumentsOffset.width; height: host.instrumentsOffset.height
      Image {
        anchors.fill: parent
        source: assembly.visible ? Quickshell.env("UG_CAPTURE_OUTPUT") + "/instruments-card.png" : ""
      }
      Image {
        x: host.instrumentsOffset.x; y: host.instrumentsOffset.y
        width: host.instrumentsOffset.popupWidth; height: host.instrumentsOffset.popupHeight
        source: assembly.visible ? Quickshell.env("UG_CAPTURE_OUTPUT") + "/instruments-list.png" : ""
      }
    }
  }

  FloatingWindow {
    id: preview
    implicitWidth: 2560; implicitHeight: 1600
    visible: false
    color: "#090503"
    Item {
      id: composition
      width: 2560; height: 1600
      Image {
        anchors.fill: parent
        source: Quickshell.env("UG_CAPTURE_WALLPAPER")
        fillMode: Image.PreserveAspectCrop
        layer.enabled: true
        layer.effect: MultiEffect { blurEnabled: true; blurMax: 16; blur: 0.7 }
      }
      Rectangle { anchors.fill: parent; color: "#a6000000" }
      Image {
        id: expandedShot
        x: 140; y: 70; width: 1188; height: 1460
        source: preview.visible ? Quickshell.env("UG_CAPTURE_OUTPUT") + "/expanded.png" : ""
        fillMode: Image.PreserveAspectFit
        layer.enabled: true
        layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.8; shadowOpacity: 0.6; shadowVerticalOffset: 20 }
      }
      Image {
        x: 1250; y: 330; width: 1088; height: 1150
        source: preview.visible ? Quickshell.env("UG_CAPTURE_OUTPUT") + "/instruments.png" : ""
        fillMode: Image.PreserveAspectFit
        layer.enabled: true
        layer.effect: MultiEffect { shadowEnabled: true; shadowBlur: 0.8; shadowOpacity: 0.6; shadowVerticalOffset: 20 }
      }
    }
  }

  IpcHandler {
    target: "capture"
    function ready(): bool { return !!probe.item && !!service.item && !!widget.item && !!host.fixtures }
    function play(): string {
      var player = Object.assign({ isPlaying: true, playbackState: 1, dbusName: "org.mpris.MediaPlayer2.fixture",
        trackArtUrl: "file://" + Quickshell.env("UG_CAPTURE_COVER") }, host.fixtures.player)
      service.item.players = [player]
      return JSON.stringify(service.item.statusObject())
    }
    function loadTab(): string {
      var s = service.item
      s.tabSerial = s.serial
      s.handleTab(JSON.stringify({ ok: true, tab: host.fixtures.tab }))
      widget.item.popupOpen = true
      return JSON.stringify(s.statusObject())
    }
    function openInstruments(): string {
      var p = host.pickers()
      if (!p.instrument) return "no instrument picker"
      p.instrument.open()
      return "ok"
    }
    function closeDropdown(): void {
      host.pickers().instrument.close()
    }
    // An offscreen window keeps the size it was first shown at, so after the
    // reader is expanded (which it saves, as it does for a user) the widget is
    // made again and opens expanded.
    function expand(): void {
      host.reader().setExpanded(true)
      widget.item.popupOpen = false
    }
    function reload(): void {
      widget.active = false
      Qt.callLater(function () { widget.active = true })
    }
    function reopen(): bool {
      if (!widget.item || !host.reader()) return false
      widget.item.popupOpen = true
      return host.reader().expanded
    }
    function geometry(): string {
      var p = host.popup()
      return JSON.stringify({ screenW: p.screenW, contentWidth: p.contentWidth, contentHeight: p.contentHeight,
        width: p.width, height: p.height, card: [p.captureCard.width, p.captureCard.height] })
    }
    function grab(path: string): string {
      var p = host.popup()
      if (!p) return "No popup"
      return p.captureCard.grabToImage(result => result.saveToFile(path)) ? "ok" : "Capture failed"
    }
    function grabInstrumentList(path: string): string {
      var card = host.popup().captureCard
      var list = host.dropdownPopup(host.pickers().instrument)
      if (!list || !list.opened) return "dropdown not open"
      var item = list.contentItem.parent
      var at = item.mapToItem(card, 0, 0)
      host.instrumentsOffset = { x: at.x, y: at.y, width: card.width, height: card.height,
                              popupWidth: item.width, popupHeight: item.height }
      return item.grabToImage(result => result.saveToFile(path)) ? JSON.stringify(host.instrumentsOffset) : "Capture failed"
    }
    function assembleInstruments(): void { assembly.visible = true }
    function grabInstruments(path: string): bool {
      return instrumentsShot.grabToImage(result => result.saveToFile(path))
    }
    function startProbe(helper: string): string { return probe.item.start(helper) }
    function probeResult(): string { return probe.item.output }
    function preparePreview(): void { preview.visible = true }
    function grabPreview(path: string): bool {
      return composition.grabToImage(result => result.saveToFile(path), Qt.size(1280, 800))
    }
  }
}
