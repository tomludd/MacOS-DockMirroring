import AppKit

enum DockOrientation: String {
    case bottom, left, right
}

/// Innstillinger for en mappe i Docken (fra `persistent-others`).
struct FolderTileSettings: Equatable {
    /// 1 navn, 2 dato lagt til, 3 dato endret, 4 dato opprettet, 5 type
    var arrangement = 1
    /// 0 stabel, 1 mappe
    var displayAs = 0
    /// 0 automatisk, 1 vifte, 2 rutenett, 3 liste
    var showAs = 0
}

struct PersistentTile: Equatable {
    var type: String
    var url: URL?
    var label: String
    var bundleIdentifier: String?
    var folder: FolderTileSettings
}

/// Leser Dock-innstillingene (com.apple.dock) slik at kopiene ser og oppfører seg likt.
struct DockPreferences: Equatable {
    var tileSize: CGFloat = 48
    var magnification = false
    var largeSize: CGFloat = 128
    var autohide = false
    var autohideDelay: Double = 0.5
    var autohideTimeModifier: Double = 1
    var orientation: DockOrientation = .bottom
    var showProcessIndicators = true
    var showRecents = true
    var trashFull = false
    var launchAnimation = true
    var persistentApps: [PersistentTile] = []
    var persistentOthers: [PersistentTile] = []
    var recentApps: [PersistentTile] = []

    func folderSettings(for url: URL) -> FolderTileSettings {
        let path = url.standardizedFileURL.path
        return persistentOthers.first { $0.url?.standardizedFileURL.path == path }?.folder ?? FolderTileSettings()
    }

    private static let domain = "com.apple.dock" as CFString

    static func load() -> DockPreferences {
        CFPreferencesAppSynchronize(domain)
        func get(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, domain) }
        func number(_ key: String) -> Double? { (get(key) as? NSNumber)?.doubleValue }
        func bool(_ key: String) -> Bool? { (get(key) as? NSNumber)?.boolValue }

        var p = DockPreferences()
        if let v = number("tilesize") { p.tileSize = CGFloat(min(max(v, 16), 128)).rounded() }
        if let v = bool("magnification") { p.magnification = v }
        if let v = number("largesize") { p.largeSize = CGFloat(min(max(v, 16), 128)).rounded() }
        if let v = bool("autohide") { p.autohide = v }
        if let v = number("autohide-delay") { p.autohideDelay = max(0, v) }
        if let v = number("autohide-time-modifier") { p.autohideTimeModifier = max(0, v) }
        if let v = get("orientation") as? String, let o = DockOrientation(rawValue: v) { p.orientation = o }
        if let v = bool("show-process-indicators") { p.showProcessIndicators = v }
        if let v = bool("show-recents") { p.showRecents = v }
        if let v = bool("trash-full") { p.trashFull = v }
        if let v = bool("launchanim") { p.launchAnimation = v }
        p.persistentApps = tiles(get("persistent-apps"))
        p.persistentOthers = tiles(get("persistent-others"))
        p.recentApps = tiles(get("recent-apps"))
        return p
    }

    private static func tiles(_ value: Any?) -> [PersistentTile] {
        guard let array = value as? [[String: Any]] else { return [] }
        return array.map { dict in
            let type = dict["tile-type"] as? String ?? "file-tile"
            let data = dict["tile-data"] as? [String: Any] ?? [:]
            var url: URL?
            if let fileData = data["file-data"] as? [String: Any], let s = fileData["_CFURLString"] as? String {
                let kind = (fileData["_CFURLStringType"] as? NSNumber)?.intValue ?? 15
                url = kind == 0 ? URL(fileURLWithPath: s) : URL(string: s)
            } else if let urlData = data["url"] as? [String: Any], let s = urlData["_CFURLString"] as? String {
                url = URL(string: s)
            }
            let label = (data["file-label"] as? String) ?? (data["label"] as? String)
                ?? url?.deletingPathExtension().lastPathComponent ?? ""
            var folder = FolderTileSettings()
            if let v = (data["arrangement"] as? NSNumber)?.intValue { folder.arrangement = v }
            if let v = (data["displayas"] as? NSNumber)?.intValue { folder.displayAs = v }
            if let v = (data["showas"] as? NSNumber)?.intValue { folder.showAs = v }
            return PersistentTile(type: type, url: url, label: label,
                                  bundleIdentifier: data["bundle-identifier"] as? String, folder: folder)
        }
    }
}
