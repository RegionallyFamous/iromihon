import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false
  property string phase: "entry"
  property string repoDraft: ""
  property string activeRepoUrl: ""
  property string requestedSlug: ""
  property var sourceInfo: ({})
  property var themes: []
  property int themeIndex: 0
  property int wallpaperIndex: 0
  property string statusText: ""
  property string errorText: ""
  property string inspectOutput: ""
  property string inspectError: ""
  property string actionOutput: ""
  property string actionError: ""
  property string actionKind: ""
  property bool restoreAttempted: false
  property string preferenceDesiredMode: ""
  property string preferenceDesiredUrl: ""
  property string preferenceDesiredSlug: ""
  property string preferenceError: ""
  property bool closeAfterAction: false
  property int requestSerial: 0

  readonly property bool busy: phase === "loading" || phase === "working"
  readonly property string defaultRepositoryUrl: "https://github.com/RegionallyFamous/iromihon-themes.git"
  readonly property var selectedTheme: themes.length > 0 && themeIndex >= 0 && themeIndex < themes.length ? themes[themeIndex] : null
  readonly property var selectedWallpapers: selectedTheme && Array.isArray(selectedTheme.wallpapers) ? selectedTheme.wallpapers : []
  readonly property string selectedWallpaper: Model.wallpaperPath(selectedTheme, wallpaperIndex)
  readonly property string focusedScreenName: Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("./manifest.json"))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    try { url = decodeURIComponent(url) } catch (e) {}
    var slash = url.lastIndexOf("/")
    return slash > 0 ? url.slice(0, slash) : url
  }
  readonly property string sourceCommand: pluginDir + "/scripts/source-command"

  onThemeIndexChanged: wallpaperIndex = 0
  onThemesChanged: wallpaperIndex = 0

  function open(payload) {
    var args = {}
    if (payload) {
      try { args = JSON.parse(payload) || {} } catch (e) { args = {} }
    }
    opened = true
    errorText = ""
    statusText = ""
    if (typeof args.url === "string" && args.url.length > 0) {
      repoDraft = args.url
      inspectRepository(repoDraft)
    } else if (themes.length > 0) {
      phase = "browse"
    } else if (!restoreAttempted) {
      restoreSelection()
    } else {
      phase = "entry"
    }
  }

  function close() {
    if (busy) {
      statusText = "Finishing the current source operation…"
      return
    }
    opened = false
  }

  function operationError(value, fallback) {
    var message = String(value || "").trim()
    if (!message) return fallback
    if (message.length > 800) return message.slice(0, 799) + "…"
    return message
  }

  function activeScreen(screen) {
    if (!screen) return false
    if (focusedScreenName) return String(screen.name || "") === focusedScreenName
    return Quickshell.screens.length === 0 || screen === Quickshell.screens[0]
  }

  function inspectRepository(value) {
    if (inspectProc.running || actionProc.running) return
    var validated = Model.validateRepositoryUrl(value)
    if (!validated.ok) {
      errorText = validated.error
      phase = "entry"
      return
    }

    activeRepoUrl = validated.baseUrl
    requestedSlug = validated.selector
    repoDraft = validated.baseUrl + (validated.selector ? "#" + validated.selector : "")
    inspectOutput = ""
    inspectError = ""
    errorText = ""
    statusText = "Reading native themes…"
    phase = "loading"
    requestSerial += 1
    inspectProc.serial = requestSerial
    inspectProc.kind = "inspect"
    inspectProc.command = [sourceCommand, "inspect", activeRepoUrl, "--json"]
    inspectProc.running = true
  }

  function restoreSelection() {
    if (inspectProc.running || actionProc.running) return
    restoreAttempted = true
    inspectOutput = ""
    inspectError = ""
    errorText = ""
    statusText = "Restoring your last selection…"
    phase = "loading"
    requestSerial += 1
    inspectProc.serial = requestSerial
    inspectProc.kind = "restore"
    inspectProc.command = [sourceCommand, "restore", "--json"]
    inspectProc.running = true
  }

  function finishInspect(serial, exitCode) {
    if (serial !== requestSerial) return
    if (exitCode !== 0) {
      errorText = operationError(inspectError, "Iromihon could not inspect this theme source.")
      phase = "error"
      return
    }

    var parsed = Model.parseSourceJson(inspectOutput)
    if (!parsed.ok) {
      errorText = parsed.error
      phase = "error"
      return
    }
    sourceInfo = parsed.source
    themes = parsed.themes
    themeIndex = Model.selectedIndex(themes, requestedSlug, 0)
    statusText = ""
    phase = "browse"
    rememberSelection()
    Qt.callLater(function() { keySurface.forceActiveFocus() })
  }

  function finishRestore(serial, exitCode) {
    if (serial !== requestSerial) return
    if (exitCode !== 0) {
      errorText = operationError(inspectError, "Iromihon could not restore the saved selection.")
      statusText = ""
      phase = "entry"
      return
    }

    var parsed = Model.parseRestoreJson(inspectOutput)
    if (!parsed.ok) {
      errorText = parsed.error
      statusText = ""
      phase = "entry"
      return
    }
    if (!parsed.found) {
      if (parsed.useDefault) {
        repoDraft = defaultRepositoryUrl
        inspectRepository(defaultRepositoryUrl)
        return
      }
      statusText = ""
      phase = "entry"
      Qt.callLater(function() { urlField.forceActiveFocus() })
      return
    }

    sourceInfo = parsed.source
    themes = parsed.themes
    requestedSlug = parsed.slug
    activeRepoUrl = parsed.source.url
    repoDraft = activeRepoUrl + "#" + requestedSlug
    themeIndex = Model.selectedIndex(themes, requestedSlug, 0)
    statusText = ""
    phase = "browse"
    Qt.callLater(function() { keySurface.forceActiveFocus() })
  }

  function moveTheme(direction) {
    if (phase !== "browse" || themes.length < 2) return
    themeIndex = Model.adjacentIndex(themes.length, themeIndex, direction)
    rememberSelection()
  }

  function moveWallpaper(direction) {
    if (phase !== "browse" || selectedWallpapers.length < 2) return
    wallpaperIndex = Model.adjacentIndex(selectedWallpapers.length, wallpaperIndex, direction)
  }

  function rememberSelection() {
    var theme = selectedTheme
    var repositoryUrl = String(sourceInfo && sourceInfo.url ? sourceInfo.url : "")
    if (!theme || !repositoryUrl) return
    preferenceDesiredMode = "remember"
    preferenceDesiredUrl = repositoryUrl
    preferenceDesiredSlug = String(theme.slug || "")
    runPreference()
  }

  function forgetSelection() {
    preferenceDesiredMode = "forget"
    preferenceDesiredUrl = ""
    preferenceDesiredSlug = ""
    runPreference()
  }

  function runPreference() {
    if (preferenceProc.running || !preferenceDesiredMode) return
    var mode = preferenceDesiredMode
    var repositoryUrl = preferenceDesiredUrl
    var themeSlug = preferenceDesiredSlug
    preferenceDesiredMode = ""
    preferenceDesiredUrl = ""
    preferenceDesiredSlug = ""
    preferenceError = ""
    preferenceProc.mode = mode
    if (mode === "forget") preferenceProc.command = [sourceCommand, "forget"]
    else preferenceProc.command = [sourceCommand, "remember", repositoryUrl, themeSlug]
    preferenceProc.running = true
  }

  function finishPreference(mode, exitCode) {
    if (exitCode !== 0) {
      errorText = operationError(preferenceError, mode === "forget" ?
        "Iromihon could not forget the saved collection." : "Iromihon could not save this selection.")
    }
    if (preferenceDesiredMode) Qt.callLater(function() { root.runPreference() })
  }

  function installSelected(applyTheme) {
    var theme = selectedTheme
    if (!theme || actionProc.running || inspectProc.running) return
    if (theme.conflict) {
      errorText = "A different user theme already owns ‘" + theme.slug + "’. Iromihon will not replace it."
      return
    }

    actionOutput = ""
    actionError = ""
    errorText = ""
    statusText = applyTheme ? "Installing and applying " + theme.name + "…" : "Installing " + theme.name + "…"
    phase = "working"
    actionKind = applyTheme ? "apply" : "install"
    closeAfterAction = applyTheme
    requestSerial += 1
    actionProc.serial = requestSerial
    var command = [sourceCommand, "install", String(sourceInfo.id || ""), theme.slug]
    if (applyTheme) command.push("--apply")
    command.push("--json")
    actionProc.command = command
    actionProc.running = true
  }

  function detachSelected() {
    var theme = selectedTheme
    if (!theme || !theme.installed || actionProc.running || inspectProc.running) return

    actionOutput = ""
    actionError = ""
    errorText = ""
    statusText = "Removing " + theme.name + " from Omarchy…"
    phase = "working"
    actionKind = "detach"
    closeAfterAction = false
    requestSerial += 1
    actionProc.serial = requestSerial
    actionProc.command = [sourceCommand, "detach", String(sourceInfo.id || ""), theme.slug, "--json"]
    actionProc.running = true
  }

  function refreshSource() {
    if (!sourceInfo || !sourceInfo.id || actionProc.running || inspectProc.running) return

    actionOutput = ""
    actionError = ""
    errorText = ""
    statusText = "Refreshing this collection…"
    phase = "working"
    actionKind = "update"
    closeAfterAction = false
    requestSerial += 1
    actionProc.serial = requestSerial
    actionProc.command = [sourceCommand, "update", String(sourceInfo.id), "--json"]
    actionProc.running = true
  }

  function finishAction(serial, exitCode) {
    if (serial !== requestSerial) return
    if (exitCode !== 0) {
      errorText = operationError(actionError, "Iromihon could not complete this theme operation.")
      phase = "browse"
      statusText = ""
      return
    }

    var parsed = Model.parseSourceJson(actionOutput)
    if (!parsed.ok) {
      errorText = parsed.error
      phase = "browse"
      statusText = ""
      return
    }
    var selectedSlug = selectedTheme ? selectedTheme.slug : ""
    sourceInfo = parsed.source
    themes = parsed.themes
    themeIndex = Model.selectedIndex(themes, selectedSlug, themeIndex)
    phase = "browse"
    rememberSelection()
    if (actionKind === "detach") statusText = "Removed from Omarchy."
    else if (actionKind === "update") statusText = "Collection refreshed."
    else statusText = closeAfterAction ? "Applied." : "Installed."
    Qt.callLater(function() { keySurface.forceActiveFocus() })
    if (closeAfterAction) {
      closeAfterAction = false
      closeTimer.restart()
    }
  }

  function resetSource() {
    if (busy) return
    forgetSelection()
    restoreAttempted = true
    sourceInfo = ({})
    themes = []
    themeIndex = 0
    activeRepoUrl = ""
    phase = "entry"
    errorText = ""
    statusText = ""
    requestedSlug = ""
    repoDraft = ""
  }

  Process {
    id: inspectProc
    property int serial: 0
    property string kind: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.inspectOutput = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.inspectError = String(text || "")
    }
    onExited: function(exitCode) {
      var completedSerial = serial
      var completedKind = kind
      Qt.callLater(function() {
        if (completedKind === "restore") root.finishRestore(completedSerial, exitCode)
        else root.finishInspect(completedSerial, exitCode)
      })
    }
  }

  Process {
    id: actionProc
    property int serial: 0
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionOutput = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionError = String(text || "")
    }
    onExited: function(exitCode) {
      var completedSerial = serial
      Qt.callLater(function() { root.finishAction(completedSerial, exitCode) })
    }
  }

  Process {
    id: preferenceProc
    property string mode: ""
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.preferenceError = String(text || "")
    }
    onExited: function(exitCode) {
      var completedMode = mode
      Qt.callLater(function() { root.finishPreference(completedMode, exitCode) })
    }
  }

  Timer {
    id: closeTimer
    interval: 220
    onTriggered: root.opened = false
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: overlay
      required property var modelData
      screen: modelData
      visible: root.opened && root.activeScreen(modelData)
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "iromihon"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      anchors { top: true; bottom: true; left: true; right: true }

      onVisibleChanged: if (visible) Qt.callLater(function() {
        keySurface.forceActiveFocus()
        if (root.phase === "entry") urlField.forceActiveFocus()
      })

      Rectangle {
        anchors.fill: parent
        color: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 0.94)
      }

      MouseArea {
        anchors.fill: parent
        enabled: !root.busy
        onClicked: root.close()
      }

      Item {
        id: keySurface
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          } else if (root.phase === "browse" && event.key === Qt.Key_Left) {
            root.moveTheme(-1)
            event.accepted = true
          } else if (root.phase === "browse" && event.key === Qt.Key_Right) {
            root.moveTheme(1)
            event.accepted = true
          } else if (root.phase === "browse" && event.key === Qt.Key_BracketLeft) {
            root.moveWallpaper(-1)
            event.accepted = true
          } else if (root.phase === "browse" && event.key === Qt.Key_BracketRight) {
            root.moveWallpaper(1)
            event.accepted = true
          } else if (root.phase === "browse" && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            root.installSelected(true)
            event.accepted = true
          } else if (root.phase === "browse" && (event.key === Qt.Key_I)) {
            root.installSelected(false)
            event.accepted = true
          } else if (root.phase === "browse" && (event.key === Qt.Key_D)) {
            root.detachSelected()
            event.accepted = true
          } else if (root.phase === "browse" && (event.key === Qt.Key_U)) {
            root.refreshSource()
            event.accepted = true
          } else if (root.phase === "browse" && (event.key === Qt.Key_G)) {
            root.resetSource()
            Qt.callLater(function() { urlField.forceActiveFocus() })
            event.accepted = true
          }
        }

        BorderSurface {
          id: card
          anchors.centerIn: parent
          width: Math.min(parent.width - Style.space(40), Style.space(820))
          height: Math.min(parent.height - Style.space(40), Style.space(500))
          color: Color.popups.background
          borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, 2)
          radius: Style.cornerRadius
          padding: Style.space(16)

          MouseArea { anchors.fill: parent; onClicked: {} }

          ColumnLayout {
            anchors.fill: parent
            anchors.topMargin: card.contentTopInset
            anchors.rightMargin: card.contentRightInset
            anchors.bottomMargin: card.contentBottomInset
            anchors.leftMargin: card.contentLeftInset
            spacing: Style.space(12)

            RowLayout {
              Layout.fillWidth: true

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                  text: "Iromihon"
                  textFormat: Text.PlainText
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                  font.weight: Font.Bold
                }
                Text {
                  text: "色見本  ·  THEME COLLECTION BROWSER"
                  textFormat: Text.PlainText
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                visible: root.phase === "browse"
                text: (root.themeIndex + 1) + " / " + root.themes.length
                textFormat: Text.PlainText
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            Item {
              visible: root.phase === "entry"
              Layout.fillWidth: true
              Layout.fillHeight: true

              ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width, Style.space(420))
                spacing: Style.space(14)

                Text {
                  Layout.fillWidth: true
                  text: "One repository. Pick exactly one look."
                  textFormat: Text.PlainText
                  color: Color.popups.text
                  horizontalAlignment: Text.AlignHCenter
                  font.family: Style.font.family
                  font.pixelSize: Style.font.display
                  font.weight: Font.Bold
                  wrapMode: Text.WordWrap
                }

                Text {
                  Layout.fillWidth: true
                  text: "Paste a public GitHub collection. Iromihon reads native themes/<slug>/ directories and leaves Omarchy’s normal picker clean."
                  textFormat: Text.PlainText
                  color: Color.muted
                  horizontalAlignment: Text.AlignHCenter
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }

                TextField {
                  id: urlField
                  Layout.fillWidth: true
                  text: root.repoDraft
                  placeholderText: "https://github.com/owner/theme-collection"
                  onTextChanged: root.repoDraft = text
                  onAccepted: root.inspectRepository(text)
                }

                Button {
                  Layout.alignment: Qt.AlignHCenter
                  text: "Open collection"
                  bordered: true
                  active: true
                  onClicked: root.inspectRepository(urlField.text)
                }

                Text {
                  visible: root.errorText !== ""
                  Layout.fillWidth: true
                  text: root.errorText
                  textFormat: Text.PlainText
                  color: Color.urgent
                  horizontalAlignment: Text.AlignHCenter
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  maximumLineCount: 4
                  elide: Text.ElideRight
                }
              }
            }

            Item {
              visible: root.phase === "loading" || root.phase === "working"
              Layout.fillWidth: true
              Layout.fillHeight: true

              ColumnLayout {
                anchors.centerIn: parent
                spacing: Style.space(12)
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "↻"
                  textFormat: Text.PlainText
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.displayLarge
                  RotationAnimation on rotation { from: 0; to: 360; duration: 900; loops: Animation.Infinite; running: true }
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: root.statusText
                  textFormat: Text.PlainText
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                Text {
                  Layout.alignment: Qt.AlignHCenter
                  text: "The operation is bounded and cannot be cancelled halfway through."
                  textFormat: Text.PlainText
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Item {
              visible: root.phase === "error"
              Layout.fillWidth: true
              Layout.fillHeight: true

              ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width, Style.space(420))
                spacing: Style.space(14)
                Text {
                  Layout.fillWidth: true
                  text: "Collection unavailable"
                  textFormat: Text.PlainText
                  color: Color.urgent
                  horizontalAlignment: Text.AlignHCenter
                  font.family: Style.font.family
                  font.pixelSize: Style.font.display
                  font.weight: Font.Bold
                }
                Text {
                  Layout.fillWidth: true
                  text: root.errorText
                  textFormat: Text.PlainText
                  color: Color.popups.text
                  horizontalAlignment: Text.AlignHCenter
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  maximumLineCount: 8
                  elide: Text.ElideRight
                }
                Button {
                  Layout.alignment: Qt.AlignHCenter
                  text: "Try another source"
                  bordered: true
                  onClicked: {
                    root.resetSource()
                    Qt.callLater(function() { urlField.forceActiveFocus() })
                  }
                }
              }
            }

            Item {
              visible: root.phase === "browse" && root.selectedTheme !== null
              Layout.fillWidth: true
              Layout.fillHeight: true

              RowLayout {
                anchors.fill: parent
                spacing: Style.space(12)

                Button {
                  text: "‹"
                  fontSize: Style.font.display
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(16)
                  onClicked: root.moveTheme(-1)
                }

                BorderSurface {
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  color: root.selectedTheme && root.selectedTheme.colors.background ? root.selectedTheme.colors.background : Color.background
                  borderSpec: Border.controlSpec("normal", Color.popups.text, Color.accent)
                  radius: Style.cornerRadius
                  clip: true

                  Image {
                    anchors.fill: parent
                    source: Model.fileUrl(root.selectedWallpaper)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                  }

                  Rectangle {
                    visible: root.selectedWallpapers.length > 1
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: Style.space(10)
                    implicitWidth: wallpaperControls.implicitWidth + Style.space(8)
                    implicitHeight: wallpaperControls.implicitHeight + Style.space(6)
                    radius: Style.cornerRadius
                    color: Qt.rgba(0, 0, 0, 0.72)

                    Row {
                      id: wallpaperControls
                      anchors.centerIn: parent
                      spacing: Style.space(4)

                      Button {
                        text: "‹"
                        horizontalPadding: Style.space(5)
                        verticalPadding: Style.space(1)
                        onClicked: root.moveWallpaper(-1)
                      }

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: (root.wallpaperIndex + 1) + " / " + root.selectedWallpapers.length
                        textFormat: Text.PlainText
                        color: "#ffffff"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.weight: Font.Bold
                      }

                      Button {
                        text: "›"
                        horizontalPadding: Style.space(5)
                        verticalPadding: Style.space(1)
                        onClicked: root.moveWallpaper(1)
                      }
                    }
                  }

                  Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Math.min(parent.height * 0.42, Style.space(150))
                    gradient: Gradient {
                      GradientStop { position: 0; color: "transparent" }
                      GradientStop { position: 0.34; color: Qt.rgba(0, 0, 0, 0.62) }
                      GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.94) }
                    }
                  }

                  ColumnLayout {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(14)
                    spacing: Style.space(6)

                    RowLayout {
                      Layout.fillWidth: true
                      Text {
                        Layout.fillWidth: true
                        text: root.selectedTheme ? root.selectedTheme.name : ""
                        textFormat: Text.PlainText
                        color: "#ffffff"
                        font.family: Style.font.family
                        font.pixelSize: Style.font.display
                        font.weight: Font.Bold
                      }
                      Rectangle {
                        implicitWidth: statusLabel.implicitWidth + Style.space(12)
                        implicitHeight: statusLabel.implicitHeight + Style.space(6)
                        radius: Style.cornerRadius
                        color: root.selectedTheme && root.selectedTheme.conflict ? Color.urgent : Qt.rgba(1, 1, 1, 0.16)
                        Text {
                          id: statusLabel
                          anchors.centerIn: parent
                          text: Model.statusLabel(root.selectedTheme)
                          textFormat: Text.PlainText
                          color: "#ffffff"
                          font.family: Style.font.family
                          font.pixelSize: Style.font.caption
                          font.weight: Font.Bold
                        }
                      }
                    }

                    Row {
                      spacing: Style.space(4)
                      Repeater {
                        model: Model.palette(root.selectedTheme)
                        Rectangle {
                          required property var modelData
                          width: Style.space(20)
                          height: Style.space(7)
                          radius: Math.min(Style.cornerRadius, height / 2)
                          color: modelData
                          border.width: 1
                          border.color: Qt.rgba(1, 1, 1, 0.32)
                        }
                      }
                    }

                    Flow {
                      Layout.fillWidth: true
                      Layout.preferredHeight: Style.space(20)
                      spacing: Style.space(4)

                      Repeater {
                        model: Model.capabilityLabels(root.selectedTheme)

                        Rectangle {
                          required property var modelData
                          implicitWidth: capabilityLabel.implicitWidth + Style.space(10)
                          implicitHeight: capabilityLabel.implicitHeight + Style.space(4)
                          radius: Style.cornerRadius
                          color: Qt.rgba(0, 0, 0, 0.54)
                          border.width: 1
                          border.color: Qt.rgba(1, 1, 1, 0.24)

                          Text {
                            id: capabilityLabel
                            anchors.centerIn: parent
                            text: modelData
                            textFormat: Text.PlainText
                            color: "#ffffff"
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.weight: Font.Bold
                          }
                        }
                      }
                    }
                  }
                }

                Button {
                  text: "›"
                  fontSize: Style.font.display
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(16)
                  onClicked: root.moveTheme(1)
                }
              }
            }

            RowLayout {
              visible: root.phase === "browse"
              Layout.fillWidth: true
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                text: root.errorText || root.statusText || "← → theme · [ ] wallpaper · U refresh · I install · D remove · Esc close"
                textFormat: Text.PlainText
                color: root.errorText ? Color.urgent : Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              Button {
                text: "Change source"
                bordered: true
                onClicked: {
                  root.resetSource()
                  Qt.callLater(function() { urlField.forceActiveFocus() })
                }
              }

              Button {
                visible: root.selectedTheme
                text: root.selectedTheme && root.selectedTheme.installed ? "Remove" : "Install only"
                bordered: true
                enabled: root.selectedTheme && !root.selectedTheme.conflict
                onClicked: {
                  if (root.selectedTheme && root.selectedTheme.installed) root.detachSelected()
                  else root.installSelected(false)
                }
              }

              Button {
                text: root.selectedTheme && root.selectedTheme.installed ? "Apply theme" : "Install & apply"
                bordered: true
                active: true
                enabled: root.selectedTheme && !root.selectedTheme.conflict
                onClicked: root.installSelected(true)
              }
            }
          }
        }
      }
    }
  }
}
