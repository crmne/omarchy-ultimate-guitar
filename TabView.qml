import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Contents of the bar popup: the tab itself plus the controls for reading it.
// Everything network-facing lives in Service.qml; this file only renders what
// the service has already loaded.
//
// The controls sit in a column pinned to the top, the attribution line is
// pinned to the bottom, and the tab fills whatever is left. That way a long
// tab can use the full height the popup is allowed, while the panel still
// shrinks around a short one.
Item {
  id: root

  property QtObject bar: null
  property QtObject service: null
  // The popup is only mounted while open, but auto-scroll should also stop
  // when it is hidden behind a screen change.
  property bool active: false

  // How tall the reader may grow, handed down by the bar widget from the
  // popup's screen geometry. Zero until that geometry is known.
  property real maxPanelHeight: 0

  readonly property var tab: service ? service.tab : null
  readonly property string lookupState: service ? service.lookupState : "idle"
  readonly property bool ready: lookupState === "ready" && !!tab
  readonly property color foreground: bar ? bar.barForeground : Color.popups.text
  readonly property color chordColor: Color.accent
  readonly property color subtle: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.55)

  // Reading preferences outlive the popup, and there is no shell API to write
  // back into a widget's shell.json entry, so they get their own state file.
  property int fontSize: 13
  property real scrollSpeed: 1.0
  property bool autoScroll: false
  // Opens modest by default and grows to the share of the screen set in bar
  // settings when asked to.
  property bool expanded: false
  property bool preferencesLoaded: false

  // Seeded from bar settings. Binding, not assignment, so the setting keeps
  // applying until someone picks an instrument here -- after that the panel's
  // own choice is the one that persists.
  property string defaultInstrument: "guitar"
  property string instrument: defaultInstrument

  readonly property int minFontSize: 9
  readonly property int maxFontSize: 26

  readonly property var lines: ready ? Model.tabLines(tab.content, chordColor) : []
  readonly property string widestLine: ready ? Model.longestLine(tab.content) : ""
  readonly property int lineHeight: Math.ceil(lineFont.height * 1.15)

  readonly property int gap: Style.space(8)
  // Both derived from the line count and the font rather than from laid-out
  // text: the popup takes its height from here, so measuring the rendered tab
  // to size it would feed geometry back into what produced it.
  readonly property real naturalBodyHeight: Math.max(Style.space(120), lines.length * lineHeight)
  readonly property real chromeHeight: chrome.implicitHeight + footer.implicitHeight + gap * 2

  readonly property real compactBodyHeight: Style.space(420)

  implicitWidth: Style.space(560)
  implicitHeight: {
    var body = expanded ? naturalBodyHeight
                        : Math.min(naturalBodyHeight, compactBodyHeight)
    var wanted = chromeHeight + body
    return maxPanelHeight > 0 ? Math.min(maxPanelHeight, wanted) : wanted
  }

  FontMetrics {
    id: lineFont
    font.family: "monospace"
    font.pixelSize: root.fontSize
  }

  TextMetrics {
    id: lineMetrics
    font.family: "monospace"
    font.pixelSize: root.fontSize
    text: root.widestLine
  }

  function applyPreferences(raw) {
    try {
      var stored = JSON.parse(String(raw || "{}"))
      if (stored.fontSize) fontSize = Math.max(minFontSize, Math.min(maxFontSize, Number(stored.fontSize)))
      if (stored.scrollSpeed) scrollSpeed = Math.max(0.2, Math.min(5, Number(stored.scrollSpeed)))
      if (stored.expanded !== undefined) expanded = stored.expanded === true
      if (stored.instrument) instrument = Model.normalizeInstrument(stored.instrument)
    } catch (error) {
      // A corrupt state file just means defaults.
    }
    preferencesLoaded = true
  }

  function savePreferences() {
    if (!preferencesLoaded) return
    preferencesFile.setText(JSON.stringify({
      fontSize: fontSize,
      scrollSpeed: scrollSpeed,
      expanded: expanded,
      instrument: instrument
    }, null, 2) + "\n")
  }

  function setInstrument(value) {
    var next = Model.normalizeInstrument(value)
    if (next === instrument) return
    instrument = next
    savePreferences()
  }

  function setExpanded(value) {
    if (expanded === value) return
    expanded = value
    savePreferences()
  }

  function setFontSize(size) {
    var next = Math.max(minFontSize, Math.min(maxFontSize, Math.round(size)))
    if (next === fontSize) return
    fontSize = next
    savePreferences()
  }

  FileView {
    id: preferencesFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/ultimate-guitar.json"
    printErrors: false
    onLoaded: root.applyPreferences(text())
    onLoadFailed: root.preferencesLoaded = true
  }

  // Auto-scroll pauses whenever the reader is not actually on screen.
  Timer {
    running: root.autoScroll && root.active && root.ready
      && tabFlick.contentHeight > tabFlick.height
    interval: 16
    repeat: true
    onTriggered: {
      var limit = tabFlick.contentHeight - tabFlick.height
      var next = tabFlick.contentY + root.scrollSpeed * 0.4
      if (next >= limit) {
        tabFlick.contentY = limit
        root.autoScroll = false
        return
      }
      tabFlick.contentY = next
    }
  }

  // A new tab always starts from the top, not wherever the last one was left.
  Connections {
    target: root.service
    function onTabUrlChanged() {
      tabFlick.contentY = 0
      tabFlick.contentX = 0
      root.autoScroll = false
    }
  }

  // --- header and controls, pinned to the top ------------------------------

  Column {
    id: chrome
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: root.gap

    Item {
      width: parent.width
      height: heading.implicitHeight

      Column {
        id: heading
        anchors.left: parent.left
        anchors.right: headerActions.left
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: root.tab && root.tab.song ? root.tab.song
            : (root.service && root.service.title ? root.service.title : "Nothing playing")
          color: root.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.tab && root.tab.artist ? root.tab.artist
            : (root.service ? root.service.artist : "")
          color: root.subtle
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          visible: text !== ""
        }
      }

      Row {
        id: headerActions
        anchors.right: parent.right
        anchors.verticalCenter: heading.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          iconText: "\u{F0450}"
          tooltipText: "Look the song up again"
          foreground: root.foreground
          enabled: !!(root.service && root.service.hasMedia)
          onClicked: if (root.service) root.service.refresh()
        }

        PanelActionButton {
          iconText: root.expanded ? "\u{F0294}" : "\u{F0293}"
          tooltipText: root.expanded ? "Back to the compact reader"
                                     : "Give the tab more room"
          foreground: root.expanded ? Color.accent : root.foreground
          onClicked: root.setExpanded(!root.expanded)
        }

        PanelActionButton {
          iconText: "\u{F03CC}"
          tooltipText: root.ready ? "Open this tab on ultimate-guitar.com"
                                  : "Search ultimate-guitar.com"
          foreground: root.foreground
          enabled: !!(root.service && (root.service.tabUrl || root.service.searchUrl))
          onClicked: {
            if (!root.service) return
            if (root.service.tabUrl) root.service.openCurrent()
            else root.service.openSearch()
          }
        }
      }
    }

    Text {
      width: parent.width
      text: Model.metaLine(root.tab)
      color: root.subtle
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      visible: root.ready && text !== ""
    }

    // Official tabs are a Guitar Pro-style binary that only Ultimate Guitar's
    // own player can render, so this is a link out rather than another version.
    Button {
      width: parent.width
      visible: !!(root.service && root.service.hasOfficial)
      text: "Official tab available"
      iconText: "\u{F0771}"
      tooltipText: "Opens the official tab in your browser, where your Ultimate Guitar session lives"
      foreground: root.foreground
      accent: Color.accent
      bordered: true
      onClicked: if (root.service) root.service.openOfficial()
    }

    Item {
      width: parent.width
      height: controls.implicitHeight
      visible: root.ready

      Row {
        id: controls
        width: parent.width
        spacing: Style.space(6)

        // Row has no alignment of its own, so every child centers itself
        // against the tallest one -- the dropdowns.
        Dropdown {
          id: instrumentPicker
          // Fixed: it only ever holds one of five short labels, so growing it
          // with the panel would just steal room from the version label.
          width: Style.space(124)
          anchors.verticalCenter: parent.verticalCenter
          label: "Instrument"
          showLabel: false
          foreground: root.foreground
          value: root.instrument
          options: {
            var list = []
            for (var i = 0; i < Model.INSTRUMENTS.length; i++) {
              list.push({ label: Model.INSTRUMENTS[i].label, value: Model.INSTRUMENTS[i].id })
            }
            return list
          }
          onChanged: function (value) { root.setInstrument(value) }
        }

        Dropdown {
          id: versionPicker
          // Takes everything the fixed-width controls leave, so the rating and
          // vote count survive instead of being elided away.
          width: Math.max(Style.space(130),
                          controls.width - instrumentPicker.width - playButton.width
                            - speedSlider.width - smallerButton.width - biggerButton.width
                            - controls.spacing * 5)
          anchors.verticalCenter: parent.verticalCenter
          label: "Version"
          showLabel: false
          foreground: root.foreground
          value: root.service ? root.service.tabUrl : ""
          options: {
            var list = []
            var versions = root.service ? root.service.versions : []
            for (var i = 0; i < versions.length; i++) {
              list.push({ label: Model.versionLabel(versions[i]), value: String(versions[i].url) })
            }
            // The tab on screen is not always in its own version list.
            if (root.tab && root.tab.url && !list.some(function (o) { return o.value === root.tab.url })) {
              list.unshift({ label: Model.versionLabel(root.tab), value: String(root.tab.url) })
            }
            return list
          }
          onChanged: function (value) {
            if (root.service && value && value !== root.service.tabUrl) root.service.loadTab(value)
          }
        }

        PanelActionButton {
          id: playButton
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.autoScroll ? "\u{F03E4}" : "\u{F040A}"
          tooltipText: root.autoScroll ? "Pause auto-scroll" : "Auto-scroll while you play"
          foreground: root.autoScroll ? Color.accent : root.foreground
          onClicked: root.autoScroll = !root.autoScroll
        }

        PanelSlider {
          id: speedSlider
          // Capped: past a point a longer slider buys no precision, and the
          // width is better spent on the version label.
          width: Math.min(Style.space(130), Math.max(Style.space(70), parent.width * 0.18))
          anchors.verticalCenter: parent.verticalCenter
          bar: root.bar
          minimum: 0.2
          maximum: 5
          step: 0.1
          value: root.scrollSpeed
          onMoved: function (value) { root.scrollSpeed = value }
          onReleased: function (value) {
            root.scrollSpeed = value
            root.savePreferences()
          }
        }

        PanelActionButton {
          id: smallerButton
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F0374}"
          tooltipText: "Smaller text"
          foreground: root.foreground
          enabled: root.fontSize > root.minFontSize
          onClicked: root.setFontSize(root.fontSize - 1)
        }

        PanelActionButton {
          id: biggerButton
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\u{F0415}"
          tooltipText: "Bigger text"
          foreground: root.foreground
          enabled: root.fontSize < root.maxFontSize
          onClicked: root.setFontSize(root.fontSize + 1)
        }
      }
    }

    PanelSeparator {
      width: parent.width
      foreground: root.foreground
      visible: root.ready
    }
  }

  // --- the tab, filling everything between chrome and footer ---------------

  // One delegate per line rather than one text item for the whole tab. A
  // 250-line tablature laid out as a single non-wrapping rich text item takes
  // seconds, and Qt pays it again every time the popup is shown; this way only
  // the lines actually on screen are ever laid out.
  ListView {
    id: tabFlick
    anchors.top: chrome.bottom
    anchors.bottom: footer.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: root.gap
    anchors.bottomMargin: root.gap
    visible: root.ready
    clip: true
    model: root.lines
    // Chord sheets and tablature are column-aligned, so lines never wrap; the
    // view pans sideways to the width of the longest one instead.
    contentWidth: Math.max(width, lineMetrics.width)
    flickableDirection: Flickable.HorizontalAndVerticalFlick
    boundsBehavior: Flickable.StopAtBounds
    // Anchored between chrome and footer, so height is briefly negative while
    // the popup is still laying itself out.
    cacheBuffer: Math.max(0, Math.round(height))
    reuseItems: true

    // Reading a tab by hand and auto-scrolling are mutually exclusive.
    onMovementStarted: root.autoScroll = false

    delegate: Text {
      required property var modelData
      width: tabFlick.contentWidth
      height: root.lineHeight
      text: modelData.text
      textFormat: modelData.rich ? Text.RichText : Text.PlainText
      color: root.foreground
      font.family: "monospace"
      font.pixelSize: root.fontSize
      verticalAlignment: Text.AlignVCenter
    }
  }

  // --- everything that is not a loaded tab, in the same space --------------

  Item {
    anchors.fill: tabFlick
    visible: !root.ready

    Column {
      anchors.centerIn: parent
      width: parent.width
      spacing: Style.space(8)

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        color: root.subtle
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        wrapMode: Text.WordWrap
        text: {
          switch (root.lookupState) {
          case "idle": return "Play something and its tab shows up here."
          case "searching": return "Looking for a tab…"
          case "loading": return "Loading the tab…"
          case "empty": return root.tab
            ? "This version has no text to show."
            : "No tab on Ultimate Guitar for this one."
          case "error": return root.service ? root.service.errorText : "Something went wrong."
          }
          return ""
        }
      }

      Button {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.lookupState === "empty" || root.lookupState === "error"
        text: "Search on Ultimate Guitar"
        iconText: "\u{F0349}"
        foreground: root.foreground
        bordered: true
        onClicked: if (root.service) root.service.openSearch()
      }
    }
  }

  // --- footer, pinned to the bottom ----------------------------------------

  Text {
    id: footer
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    horizontalAlignment: Text.AlignRight
    color: root.subtle
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
    text: root.ready ? "ultimate-guitar.com" : ""
  }
}
