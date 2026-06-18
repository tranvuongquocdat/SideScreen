import Foundation
import ServiceManagement
import os.log

@available(macOS 13.0, *)
class DaemonManager {
    static let shared = DaemonManager()
    
    // The name of the plist file that will be placed in Contents/Library/LaunchDaemons/
    private let plistName = "com.sidescreen.daemon.plist"
    
    private var appService: SMAppService {
        return SMAppService.daemon(plistName: plistName)
    }
    
    var isEnabled: Bool {
        return appService.status == .enabled
    }
    
    func enable() throws {
        let service = appService
        guard service.status != .enabled else { return }
        
        do {
            try service.register()
            os_log("Successfully registered daemon.")
        } catch {
            os_log("Failed to register daemon: %{public}@", error.localizedDescription)
            throw error
        }
    }
    
    func disable() throws {
        let service = appService
        guard service.status != .notRegistered else { return }
        
        do {
            try service.unregister()
            os_log("Successfully unregistered daemon.")
        } catch {
            os_log("Failed to unregister daemon: %{public}@", error.localizedDescription)
            throw error
        }
    }
}
