import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// KeePass lookup from the bar. Left click opens a panel that asks for the
// master password once, then turns into a search box: type, arrow to an
// entry, Enter copies its password to the clipboard and the agent scrubs it
// again a few seconds later.
//
// All database work happens in the kp-agent helper, which keeps the decrypted
// database in its own process and forgets it after `idleTimeout` seconds. The
// widget only ever holds titles and usernames.
Panel {
  id: root
  moduleName: "ignace.keepass"
  ipcTarget: "ignace.keepass"

  // Configurable from shell.json. These must go through setting(): the bar
  // injects the entry as `settings` and never assigns plain properties, so a
  // bare `property string dbPath` would stay empty however shell.json reads.
  // Bindings, not one-shot assignments -- `settings` arrives after the
  // component loads.
  //
  // The fallbacks here mirror manifest barWidget.defaults; the shell does not
  // merge those in for us.
  readonly property string dbPath: String(conf("dbPath", "~/Database.kdbx")).trim()
  readonly property string keyfile: String(conf("keyfile", "")).trim()
  readonly property int idleTimeout: Math.max(30, Math.min(86400, Number(setting("idleTimeout", 600)) || 600))
  readonly property int clearAfter: Math.max(0, Math.min(300, Number(setting("clearAfter", 20)) || 20))

  // Where the panel keeps what it was told, so a fresh install can be pointed
  // at a database by typing the path instead of hand-editing shell.json.
  // Same location and precedence the other third-party panels use: what the
  // panel saved wins, and shell.json is the starting value for a key the panel
  // has never written.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/settings"
  readonly property string configPath: stateDir + "/keepass.json"
  property var userConfig: ({})
  property bool editingPath: false
  property string configError: ""

  function conf(key, fallback) {
    if (userConfig && userConfig[key] !== undefined && userConfig[key] !== null)
      return userConfig[key]
    return setting(key, fallback)
  }

  function applyUserConfig(raw) {
    var parsed
    try {
      parsed = JSON.parse(String(raw || "{}"))
    } catch (e) {
      parsed = {}
    }
    userConfig = (parsed && typeof parsed === "object") ? parsed : ({})
  }

  function saveConfig(values) {
    var next = ({})
    for (var k in userConfig) next[k] = userConfig[k]
    for (var key in values) {
      if (values[key] === null || values[key] === "") delete next[key]
      else next[key] = values[key]
    }
    userConfig = next
    root.configError = ""
    // The directory is not there on a fresh machine, and FileView will not
    // create it.
    mkdirProc.running = true
    configFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function setDatabasePath(path) {
    var next = String(path || "").trim()
    if (next === "") return
    root.saveConfig({ dbPath: next })
    root.editingPath = false
    root.lock()
    root.refresh()
  }

  property bool unlocked: false
  property bool dbExists: true
  property int remaining: 0
  property bool busy: false
  property string errorText: ""
  property string flashText: ""
  property var results: []
  property int selectedIndex: 0
  // False until a search round-trip completes, so an unpopulated list is not
  // mistaken for an empty database.
  property bool searched: false

  readonly property string helper: Qt.resolvedUrl("kp-agent").toString().replace("file://", "")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Config-carrying prefix shared by every helper call; the agent needs it on
  // whichever call happens to spawn the daemon, so it goes on all of them.
  function helperArgs(rest) {
    var base = ["timeout", "30", root.helper, "--db", root.dbPath,
                "--timeout", String(root.idleTimeout),
                "--clear-after", String(root.clearAfter)]
    if (root.keyfile !== "") base = base.concat(["--keyfile", root.keyfile])
    return base.concat(rest)
  }

  function refresh() {
    if (!statusProc.running) {
      statusProc.command = root.helperArgs(["status"])
      statusProc.running = true
    }
  }

  function unlock(password) {
    if (root.busy || password === "") return
    root.busy = true
    root.errorText = ""
    unlockProc.secret = password
    unlockProc.command = root.helperArgs(["unlock"])
    unlockProc.running = true
  }

  function search(query) {
    if (!root.unlocked || searchProc.running) return
    searchProc.command = root.helperArgs(["search", query])
    searchProc.running = true
  }

  function copyField(field) {
    if (!root.unlocked || root.results.length === 0) return
    var entry = root.results[root.selectedIndex]
    if (!entry) return
    copyProc.command = root.helperArgs(["copy", entry.uuid, field])
    copyProc.running = true
  }

  function lock() {
    lockProc.command = root.helperArgs(["lock"])
    lockProc.running = true
    root.unlocked = false
    root.results = []
    root.searched = false
    root.flashText = ""
  }

  function move(delta) {
    if (root.results.length === 0) return
    var next = root.selectedIndex + delta
    root.selectedIndex = Math.max(0, Math.min(root.results.length - 1, next))
  }

  onOpenedChanged: {
    if (root.opened) {
      root.refresh()
      // The status poll only searches on a locked -> unlocked edge, so a panel
      // reopened while still unlocked has to ask for the list itself.
      if (root.unlocked) root.search("")
    } else {
      // Never leave a typed master password sitting in a hidden field.
      pwField.text = ""
      searchField.text = ""
      root.errorText = ""
      root.flashText = ""
      root.results = []
      root.selectedIndex = 0
      root.searched = false
      root.editingPath = false
      root.configError = ""
    }
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          var wasUnlocked = root.unlocked
          root.unlocked = data.unlocked === true
          root.remaining = data.remaining || 0
          root.dbExists = data.exists !== false
          // A fresh unlock (or one done from another window) should land on a
          // populated list rather than an empty box.
          if (root.unlocked && !wasUnlocked && root.opened) root.search(searchField.text)
        } catch (e) {}
      }
    }
  }

  Process {
    id: unlockProc
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      // Master password over stdin; argv is world-readable in /proc.
      write(secret + "\n")
      secret = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        var data = {}
        try { data = JSON.parse(text) } catch (e) {}
        if (data.ok === true) {
          root.unlocked = true
          root.errorText = ""
          pwField.text = ""
          root.search("")
          Qt.callLater(function() { searchField.forceActiveFocus() })
        } else {
          root.errorText = data.error || "Could not unlock"
          pwField.text = ""
          pwField.forceActiveFocus()
        }
      }
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok === true) {
            root.results = data.results || []
            root.selectedIndex = 0
            root.searched = true
          } else if (data.locked === true) {
            root.unlocked = false
            root.results = []
            root.searched = false
          }
        } catch (e) {}
      }
    }
  }

  Process {
    id: copyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = {}
        try { data = JSON.parse(text) } catch (e) {}
        if (data.ok === true) {
          root.flashText = (data.field === "username" ? "Username" : "Password")
                           + " copied — clears in " + (data.clearAfter || root.clearAfter) + "s"
          flashTimer.restart()
        } else {
          root.flashText = data.error || "Copy failed"
          flashTimer.restart()
        }
      }
    }
  }

  Process { id: lockProc }

  // FileView will not create the directory, and it is not there on a fresh
  // machine. The file itself lands at whatever the umask gives -- it holds a
  // path and nothing else, and a home directory is 0700 on any sane system.
  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
  }

  // Holds only the database path -- never the master password, and never
  // anything read out of the database.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    blockWrites: true
    printErrors: false

    onLoaded: root.applyUserConfig(text())
    onFileChanged: reload()
    onSaveFailed: root.configError = "Could not save to " + root.configPath
  }

  Timer {
    id: flashTimer
    interval: 3000
    onTriggered: root.flashText = ""
  }

  // Typing shouldn't fire one helper process per keystroke.
  Timer {
    id: searchDebounce
    interval: 120
    onTriggered: root.search(searchField.text)
  }

  // Keeps the countdown and the bar glyph honest while the panel is open.
  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: !root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A key rather than a padlock: the VPN widget next door already owns the
    // padlock glyphs, and two near-identical locks in one cluster read as one
    // control. Colour carries the state that matters -- an open vault.
    text: "\uF084"
    active: root.unlocked
    slotSize: Style.bar.iconSlot
    tooltipText: root.unlocked
                 ? "KeePass — unlocked, locks in " + Math.ceil(root.remaining / 60) + "m"
                 : "KeePass — locked"
    onPressed: function(b) {
      // Right click is the quick "lock it now" escape hatch.
      if (b === Qt.RightButton && root.unlocked) root.lock()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.unlocked ? searchField : (pathField.visible ? pathField : pwField)
    contentWidth: panel.fittedContentWidth(Style.space(330))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The text fields own the keyboard while the panel is open; the catcher
      // is here so Tab still moves between bar panels.
      blocked: true
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(8)

        PanelSectionHeader {
          text: "KEEPASS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        // ---- locked -------------------------------------------------------

        // A missing database is a question, not an error: ask for the path
        // rather than telling someone to go and edit shell.json.
        Text {
          width: column.width
          visible: !root.unlocked && (!root.dbExists || root.editingPath)
          text: root.dbExists ? "Database file" : "No database found. Where is it?"
          wrapMode: Text.Wrap
          color: root.bar.foreground
          opacity: 0.7
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        TextField {
          id: pathField
          width: column.width
          visible: !root.unlocked && (!root.dbExists || root.editingPath)
          placeholderText: "~/Database.kdbx"
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          onAccepted: root.setDatabasePath(text)
          Keys.onEscapePressed: {
            if (root.editingPath) root.editingPath = false
            else root.close()
          }
          // Seed with the path in force so it can be corrected rather than
          // retyped, and only when it appears -- never mid-edit.
          onVisibleChanged: if (visible) {
            text = root.dbPath
            Qt.callLater(forceActiveFocus)
          }
        }

        Text {
          width: column.width
          visible: pathField.visible
          text: root.configError !== "" ? root.configError : "Enter to save"
          wrapMode: Text.Wrap
          color: root.bar.foreground
          opacity: root.configError !== "" ? 0.9 : 0.45
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        TextField {
          id: pwField
          width: column.width
          visible: !root.unlocked && root.dbExists && !root.editingPath
          password: true
          enabled: !root.busy
          placeholderText: root.busy ? "Unlocking…" : "Master password"
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          onAccepted: root.unlock(text)
          Keys.onEscapePressed: root.close()
        }

        // ---- unlocked -----------------------------------------------------

        TextField {
          id: searchField
          width: column.width
          visible: root.unlocked
          placeholderText: "Search entries"
          foreground: root.bar.foreground
          font.family: root.bar.fontFamily
          onTextChanged: searchDebounce.restart()
          Keys.onEscapePressed: root.close()
          Keys.onUpPressed: root.move(-1)
          Keys.onDownPressed: root.move(1)
          // Enter takes the password, Shift+Enter the username -- the two
          // things you actually want on the clipboard.
          Keys.onReturnPressed: function(event) {
            root.copyField(event.modifiers & Qt.ShiftModifier ? "username" : "password")
          }
          Keys.onEnterPressed: function(event) {
            root.copyField(event.modifiers & Qt.ShiftModifier ? "username" : "password")
          }
        }

        ListView {
          id: list
          width: column.width
          visible: root.unlocked && root.results.length > 0
          height: visible ? Math.min(contentHeight, Style.space(210)) : 0
          clip: true
          interactive: contentHeight > height
          model: root.results
          currentIndex: root.selectedIndex
          onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

          delegate: Rectangle {
            required property int index
            required property var modelData

            width: list.width
            height: Style.space(34)
            radius: Style.cornerRadius
            color: index === root.selectedIndex
                   ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g,
                             root.bar.foreground.b, 0.12)
                   : "transparent"

            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.rightMargin: Style.spacing.controlPaddingX
              spacing: Style.space(1)

              Text {
                width: parent.width
                text: modelData.title
                elide: Text.ElideRight
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                width: parent.width
                visible: modelData.username !== ""
                text: modelData.username
                elide: Text.ElideRight
                color: root.bar.foreground
                opacity: 0.5
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              anchors.fill: parent
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(mouse) {
                root.selectedIndex = index
                root.copyField(mouse.button === Qt.RightButton ? "username" : "password")
              }
            }
          }
        }

        Text {
          width: column.width
          visible: root.unlocked && root.results.length === 0 && root.searched
          text: searchField.text === "" ? "Database is empty" : "No match"
          color: root.bar.foreground
          opacity: 0.5
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---- footer -------------------------------------------------------

        PanelSeparator {}

        Text {
          width: column.width
          text: {
            if (root.errorText !== "") return root.errorText
            if (root.flashText !== "") return root.flashText
            if (!root.unlocked) return "Enter to unlock"
            return "⏎ password    ⇧⏎ username    locks in "
                   + Math.ceil(root.remaining / 60) + "m"
          }
          visible: !pathField.visible
          wrapMode: Text.Wrap
          color: root.bar.foreground
          opacity: root.errorText !== "" ? 0.9 : 0.5
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          width: column.width
          // Only offered while locked: switching database out from under an
          // unlocked vault would leave the agent holding the old one.
          visible: !root.unlocked && root.dbExists && !root.editingPath
          text: "Change database…"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          leftAlign: true
          bordered: true
          onClicked: root.editingPath = true
        }

        Button {
          width: column.width
          visible: root.unlocked
          text: "Lock now"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          leftAlign: true
          bordered: true
          onClicked: root.lock()
        }

        Button {
          width: column.width
          text: "Open KeePass"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
          leftAlign: true
          bordered: true
          onClicked: {
            root.close()
            if (root.bar) root.bar.run("keepass")
          }
        }
      }
    }
  }
}
