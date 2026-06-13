import Foundation
import ServiceManagement

/// F73: SMAppService wrapper for the Settings → General → "Launch at
/// login" toggle. Reads/writes the system's login-item registration
/// for yawac's main app bundle. Sandboxed-permission failures are
/// logged but don't crash; the toggle's AppStorage value still
/// reflects user intent.
enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Apply `enabled` to the system. Returns the resulting status so
    /// the caller can decide whether to surface a warning.
    @discardableResult
    static func apply(_ enabled: Bool) -> SMAppService.Status {
        let svc = SMAppService.mainApp
        do {
            if enabled {
                try svc.register()
            } else {
                try svc.unregister()
            }
        } catch {
            NSLog("[yawac/launchAtLogin] %@ failed: %@",
                  enabled ? "register" : "unregister",
                  String(describing: error))
        }
        return svc.status
    }
}
