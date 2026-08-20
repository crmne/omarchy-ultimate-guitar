import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar entry point: a guitar glyph that lights up when the song playing has a
// tab, and opens the reader when clicked.
BarWidget {
  id: root
  moduleName: "crmne.ultimate-guitar"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("crmne.ultimate-guitar") : null
  readonly property string lookupState: service ? service.lookupState : "idle"
  readonly property bool hasMedia: service ? service.hasMedia : false
  readonly property bool ready: lookupState === "ready"
  readonly property bool busy: service ? service.busy : false

  readonly property string preferredType: String(setting("preferredType", "tabs"))
  readonly property bool hideWhenIdle: setting("hideWhenIdle", true) === true
  // Share of the screen the reader may take. Tabs are long and column-aligned,
  // so they want height above all; half the width fits most of them without
  // burying the desktop.
  readonly property int panelWidthPercent: Math.max(20, Math.min(100, Number(setting("panelWidthPercent", 50))))
  readonly property int panelHeightPercent: Math.max(30, Math.min(100, Number(setting("panelHeightPercent", 100))))

  property bool popupOpen: false

  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }

  // The widget owns the settings; the service owns the lookups. Push one into
  // the other whenever either side appears or changes.
  function syncService() {
    if (!service) return
    service.preferredType = preferredType
  }

  onServiceChanged: syncService()
  onPreferredTypeChanged: syncService()
  Component.onCompleted: syncService()

  visible: hasMedia || !hideWhenIdle
  implicitWidth: visible ? (vertical ? barSize : button.implicitWidth) : 0
  implicitHeight: barSize

  Connections {
    target: root.service
    function onToggleRequested() { root.toggle() }
    function onOpenRequested() { root.popupOpen = true }
    function onCloseRequested() { root.popupOpen = false }
  }

  onPopupOpenChanged: if (service) service.panelOpen = popupOpen

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{F0771}"
    // Dimmed while there is nothing to open: still looking, or nothing found.
    dimmed: !root.ready
    tooltipText: {
      if (!root.hasMedia) return "Ultimate Guitar"
      var song = root.service ? root.service.nowPlaying : ""
      switch (root.lookupState) {
      case "searching": return "Looking for a tab\n" + song
      case "loading": return "Loading the tab\n" + song
      case "ready": return song + (root.service && root.service.tab
        ? "\n" + String(root.service.tab.type || "") + " tab" : "")
      case "empty": return "No tab found\n" + song
      case "error": return root.service ? root.service.errorText : "Ultimate Guitar"
      }
      return song
    }

    // WidgetButton owns the mouse area and registers its click region with the
    // bar; a MouseArea laid over the top never gets the events, only hover.
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.MiddleButton) {
        if (root.service) root.service.refresh()
      } else if (mouseButton === Qt.RightButton) {
        if (!root.service) return
        // Straight to the browser, skipping the reader.
        if (root.service.tabUrl) root.service.openCurrent()
        else if (root.service.searchUrl) root.service.openSearch()
      } else {
        root.toggle()
      }
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(
      reader.expanded && popup.screenW > 0
        ? popup.screenW * root.panelWidthPercent / 100
        : Style.space(560))
    contentHeight: popup.fittedContentHeight(reader.implicitHeight)
    onOpenChanged: if (!open) root.popupOpen = false

    TabView {
      id: reader
      anchors.fill: parent
      bar: root.bar
      service: root.service
      active: root.popupOpen
      // availableCardHeight already excludes the bar and the popup's margins;
      // the inset comes off so the card itself lands on the wanted share.
      maxPanelHeight: popup.availableCardHeight > 0
        ? popup.availableCardHeight * root.panelHeightPercent / 100 - popup.verticalContentInset
        : 0
    }
  }
}
