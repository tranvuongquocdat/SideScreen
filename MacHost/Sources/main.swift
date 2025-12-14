import Foundation
import AppKit

print("🚀 Virtual Display Host starting...")

// Entry point
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
