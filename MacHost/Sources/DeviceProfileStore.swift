import Foundation

/// The settings that belong to one tablet rather than to the Mac: what its
/// virtual display looks like, how it is streamed, and where it sits in the
/// display arrangement. Port, connection mode and startup behaviour stay
/// global.
struct ProfileSettings: Codable, Equatable {
    var resolution: String
    var refreshRate: Int
    var hiDPI: Bool
    var rotation: Int
    var flipHorizontal: Bool
    var flipVertical: Bool
    var bitrate: Int
    var quality: String
    var gamingBoost: Bool
    var touchEnabled: Bool
    /// Display origin in the arrangement; nil until one was saved.
    var positionX: Int?
    var positionY: Int?

    /// Everything the virtual display and its capture are built from. A change
    /// here needs both rebuilt; everything else applies live. Gaming Boost is
    /// in because it pins the capture rate to 120.
    var displayShape: DisplayShape {
        DisplayShape(resolution: resolution, refreshRate: refreshRate, hiDPI: hiDPI, rotation: rotation, gamingBoost: gamingBoost)
    }

    struct DisplayShape: Equatable {
        let resolution: String
        let refreshRate: Int
        let hiDPI: Bool
        let rotation: Int
        let gamingBoost: Bool
    }
}

/// One remembered tablet and its settings.
struct DeviceProfile: Codable, Equatable, Identifiable {
    /// Profile key: the tablet's type 18 UUID, or `name:<handshake name>` for
    /// wireless clients without type 18.
    let id: String
    var name: String
    var lastConnected: Date
    var settings: ProfileSettings
}

/// Keeps the profiles of the most recently used tablets in UserDefaults,
/// silently: there is no UI over it. Only `capacity` profiles are kept —
/// saving one more drops the least recently connected for good, and that
/// tablet starts over from the last profile's settings next time. At ~350
/// bytes a profile the cap is about tidiness, not space.
final class DeviceProfileStore {
    static let userDefaultsKey = "devices.profiles"
    static let capacity = 20

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Profile key for a client that sent no type 18: wireless clients are
    /// told apart by handshake name, USB (loopback) clients not at all.
    static func fallbackKey(deviceName: String?) -> String? {
        guard let deviceName, !deviceName.isEmpty else { return nil }
        return "name:\(deviceName)"
    }

    /// Most recently connected first.
    func all() -> [DeviceProfile] {
        guard let data = defaults.data(forKey: Self.userDefaultsKey),
              let decoded = try? JSONDecoder().decode([DeviceProfile].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.lastConnected > $1.lastConnected }
    }

    func profile(id: String) -> DeviceProfile? {
        all().first { $0.id == id }
    }

    /// The profile the Mac's current settings belong to when no tablet is
    /// connected: the one used last.
    func mostRecent() -> DeviceProfile? {
        all().first
    }

    /// Insert or replace `profile`, then trim to `capacity`.
    func save(_ profile: DeviceProfile) {
        var current = all()
        current.removeAll { $0.id == profile.id }
        current.append(profile)
        current.sort { $0.lastConnected > $1.lastConnected }
        if current.count > Self.capacity {
            current.removeLast(current.count - Self.capacity)
        }
        write(current)
    }

    /// Replace the settings of an existing profile, keeping its place in the
    /// recency order. No-op for an unknown id.
    func updateSettings(_ settings: ProfileSettings, for id: String) {
        var current = all()
        guard let index = current.firstIndex(where: { $0.id == id }),
              current[index].settings != settings else { return }
        current[index].settings = settings
        write(current)
    }

    func forget(id: String) {
        var current = all()
        current.removeAll { $0.id == id }
        write(current)
    }

    func clear() {
        defaults.removeObject(forKey: Self.userDefaultsKey)
    }

    private func write(_ profiles: [DeviceProfile]) {
        let encoded = (try? JSONEncoder().encode(profiles)) ?? Data()
        defaults.set(encoded, forKey: Self.userDefaultsKey)
    }
}
