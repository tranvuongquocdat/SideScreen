import Foundation
import AppKit

print("🚀 Side Screen starting...")

let isDaemonMode = CommandLine.arguments.contains("--daemon")

// Entry point
let app = NSApplication.shared

// Setup main menu for keyboard shortcuts (Command+Q, etc.)
let mainMenu = NSMenu()

// App menu
let appMenu = NSMenu()
let appMenuItem = NSMenuItem()
appMenuItem.submenu = appMenu
appMenu.addItem(NSMenuItem(title: "About Side Screen", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(NSMenuItem(title: "Quit Side Screen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
mainMenu.addItem(appMenuItem)

// Edit menu (for standard text editing shortcuts)
let editMenu = NSMenu(title: "Edit")
let editMenuItem = NSMenuItem()
editMenuItem.submenu = editMenu
editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
mainMenu.addItem(editMenuItem)

app.mainMenu = mainMenu

let delegate = AppDelegate()
delegate.isDaemonMode = isDaemonMode

if isDaemonMode {
    app.setActivationPolicy(.accessory)
} else {
    app.setActivationPolicy(.regular)
}

app.delegate = delegate
app.run()
