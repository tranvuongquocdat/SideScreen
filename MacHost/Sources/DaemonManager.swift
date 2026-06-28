import Foundation
import ServiceManagement
import os.log

@available(macOS 13.0, *)
class DaemonManager {
    static let shared = DaemonManager()
    
    private var appService: SMAppService {
        return SMAppService.mainApp
    }
    
    var isEnabled: Bool {
        return appService.status == .enabled
    }
    
    func enable() throws {
        let service = appService
        guard service.status != .enabled else { return }
        
        do {
            try service.register()
            os_log("Successfully registered login item.")
        } catch {
            os_log("Failed to register login item: %{public}@", error.localizedDescription)
            throw error
        }
    }
    
    func disable() throws {
        let service = appService
        guard service.status != .notRegistered else { return }
        
        do {
            try service.unregister()
            os_log("Successfully unregistered login item.")
        } catch {
            os_log("Failed to unregister login item: %{public}@", error.localizedDescription)
            throw error
        }
    }
}
