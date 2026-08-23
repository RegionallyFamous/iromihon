import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var manifest: null
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("./manifest.json"))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    try { url = decodeURIComponent(url) } catch (e) {}
    var slash = url.lastIndexOf("/")
    return slash > 0 ? url.slice(0, slash) : url
  }

  Process {
    id: launcherInstaller
    command: [root.pluginDir + "/scripts/desktop-entry", root.pluginDir]
  }

  Component.onCompleted: launcherInstaller.running = true
}
