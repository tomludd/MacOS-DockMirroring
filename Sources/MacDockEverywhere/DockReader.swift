import AppKit
import ApplicationServices

/// Leser innholdet i den ekte Docken.
///
/// Med Tilgjengelighet-tilgang leses elementene direkte fra Dock-prosessen (eksakt rekkefølge,
/// merker, minimerte vinduer). Uten tilgang bygges listen fra Dock-innstillingene og kjørende apper.
/// Brukes kun fra én seriell kø.
final class DockReader {
    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    private var bundleIDs: [String: String] = [:]
    private var minimizedWindows: [(pid: pid_t, url: URL?, title: String)] = []
    /// Hva forrige skanning gjaldt: titlene i Docken og hvilke apper som kjørte.
    private var minimizedScanKey: [String] = []

    init() {
        // Standard tidsavbrudd for alle AX-kall, så en app som henger ikke stopper leseren lenge.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    func read(dockPID: pid_t?, prefs: DockPreferences, running: [RunningAppInfo]) -> [DockItem] {
        if AX.isTrusted, let dockPID, let items = readAccessibility(dockPID: dockPID, prefs: prefs, running: running),
           !items.isEmpty {
            return items
        }
        return readPreferences(prefs: prefs, running: running)
    }

    // MARK: - Via Accessibility

    private func readAccessibility(dockPID: pid_t, prefs: DockPreferences, running: [RunningAppInfo]) -> [DockItem]? {
        let app = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let list = AX.children(app).first(where: { AX.role($0) == kAXListRole }) else { return nil }

        let names = [kAXSubroleAttribute, kAXTitleAttribute, kAXURLAttribute,
                     kAXIsApplicationRunningAttribute, "AXStatusLabel", "AXProgressValue"] as CFArray
        var items: [DockItem] = []
        var usedIDs: [String: Int] = [:]

        for element in AX.children(list) {
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 6 else { continue }
            let subrole = AX.cleaned(values[0]) as? String ?? ""
            let title = AX.cleaned(values[1]) as? String ?? ""
            let url = AX.url(from: AX.cleaned(values[2]))
            let isRunning = (AX.cleaned(values[3]) as? NSNumber)?.boolValue ?? false
            let badge = (AX.cleaned(values[4]) as? String).flatMap { $0.isEmpty ? nil : $0 }
            let progress = (AX.cleaned(values[5]) as? NSNumber)?.doubleValue

            let kind: DockItemKind
            switch subrole {
            case "AXApplicationDockItem": kind = .application
            case "AXFolderDockItem": kind = .folder
            case "AXTrashDockItem": kind = .trash
            case "AXSeparatorDockItem": kind = .separator
            case "AXMinimizedWindowDockItem": kind = .minimizedWindow
            case "AXURLDockItem": kind = .url
            default:
                if let url, url.isFileURL {
                    kind = Self.isFolder(url) ? .folder : .file
                } else if url != nil {
                    kind = .url
                } else {
                    kind = title.isEmpty ? .spacer : .file
                }
            }

            var item = DockItem(id: "", kind: kind, title: title, url: url, isRunning: isRunning, badge: badge,
                                progress: progress.flatMap { $0 >= 0 && $0 <= 1 ? $0 : nil }, axElement: element)
            if kind == .application, let url { item.bundleIdentifier = bundleIdentifier(for: url) }
            item.id = uniqueID(for: item, used: &usedIDs)
            items.append(item)
        }
        assignMinimizedOwners(&items, running: running)
        return ensureSeparators(items, prefs: prefs)
    }

    /// Finner hvilken app hvert minimerte vindu tilhører (samme tittel kan forekomme flere ganger).
    private func assignMinimizedOwners(_ items: inout [DockItem], running: [RunningAppInfo]) {
        let titles = items.filter { $0.kind == .minimizedWindow }.map(\.title)
        guard !titles.isEmpty else { return }
        // Spør appene bare når noe faktisk har endret seg (ingen jevnlig skanning av alle apper).
        let scanKey = titles + running.map { String($0.pid) }
        if scanKey != minimizedScanKey {
            minimizedWindows = []
            for app in running {
                let axApp = AXUIElementCreateApplication(app.pid)
                AXUIElementSetMessagingTimeout(axApp, 0.25)
                for window in AX.elements(axApp, kAXWindowsAttribute) where AX.bool(window, kAXMinimizedAttribute) == true {
                    minimizedWindows.append((app.pid, app.url, AX.title(window) ?? ""))
                }
            }
            minimizedScanKey = scanKey
        }
        // Docken viser en forkortet tittel («Notes» for «Notes – 4 notes»), så vi matcher først
        // eksakt og deretter på starten av tittelen.
        var used = Set<Int>()
        let rules: [(String, String) -> Bool] = [{ $0 == $1 }, { Self.titleMatches($0, $1) }]
        for rule in rules {
            for i in items.indices where items[i].kind == .minimizedWindow && items[i].ownerPID == nil {
                let title = items[i].title
                guard let match = minimizedWindows.indices.first(where: {
                    !used.contains($0) && rule(minimizedWindows[$0].title, title)
                }) else { continue }
                used.insert(match)
                items[i].ownerPID = minimizedWindows[match].pid
                if items[i].url == nil { items[i].url = minimizedWindows[match].url }
            }
        }
    }

    static func titleMatches(_ full: String, _ short: String) -> Bool {
        !short.isEmpty && (full == short || full.hasPrefix(short + " "))
    }

    /// Hvis Docken ikke eksponerer skillelinjer, legger vi dem inn der den ekte Docken har dem.
    private func ensureSeparators(_ items: [DockItem], prefs: DockPreferences) -> [DockItem] {
        guard !items.contains(where: { $0.kind == .separator }) else { return items }
        var kept = Set(prefs.persistentApps.compactMap { $0.url?.standardizedFileURL.path })
        kept.insert(Self.finderURL.standardizedFileURL.path)
        var result: [DockItem] = []
        var insertedRecents = false
        var insertedOthers = false
        for item in items {
            let isApp = item.kind == .application
            let isKept = isApp && item.url.map { kept.contains($0.standardizedFileURL.path) } == true
            if isApp, !isKept, !insertedRecents, !result.isEmpty {
                result.append(separator(id: "sep:recents"))
                insertedRecents = true
            }
            if !isApp, item.kind != .spacer, !insertedOthers, !result.isEmpty {
                result.append(separator(id: "sep:others"))
                insertedOthers = true
            }
            result.append(item)
        }
        return result
    }

    // MARK: - Via innstillinger (uten Tilgjengelighet)

    private func readPreferences(prefs: DockPreferences, running: [RunningAppInfo]) -> [DockItem] {
        var runningPaths = Set<String>()
        var runningBundles = Set<String>()
        for app in running {
            if let url = app.url { runningPaths.insert(url.standardizedFileURL.path) }
            if let id = app.bundleIdentifier { runningBundles.insert(id) }
        }
        func isRunning(_ url: URL?, _ bundleID: String?) -> Bool {
            if let url, runningPaths.contains(url.standardizedFileURL.path) { return true }
            if let bundleID, runningBundles.contains(bundleID) { return true }
            return false
        }

        var items: [DockItem] = []
        var used: [String: Int] = [:]
        var listed = Set<String>()
        func add(_ item: DockItem) {
            var item = item
            item.id = uniqueID(for: item, used: &used)
            items.append(item)
        }
        func appItem(url: URL, title: String, bundleID: String?) -> DockItem {
            listed.insert(url.standardizedFileURL.path)
            let bundleID = bundleID ?? bundleIdentifier(for: url)
            return DockItem(id: "", kind: .application, title: title, url: url, bundleIdentifier: bundleID,
                            isRunning: isRunning(url, bundleID))
        }

        add(appItem(url: Self.finderURL, title: "Finder", bundleID: "com.apple.finder"))
        for tile in prefs.persistentApps {
            switch tile.type {
            case "spacer-tile", "small-spacer-tile":
                add(DockItem(id: "", kind: .spacer, title: ""))
            default:
                guard let url = tile.url else { continue }
                add(appItem(url: url, title: tile.label, bundleID: tile.bundleIdentifier))
            }
        }

        var extra: [DockItem] = []
        for app in running {
            guard let url = app.url, !listed.contains(url.standardizedFileURL.path) else { continue }
            extra.append(appItem(url: url, title: app.name, bundleID: app.bundleIdentifier))
        }
        if prefs.showRecents {
            for tile in prefs.recentApps.prefix(3) {
                guard let url = tile.url, !listed.contains(url.standardizedFileURL.path) else { continue }
                extra.append(appItem(url: url, title: tile.label, bundleID: tile.bundleIdentifier))
            }
        }
        if !extra.isEmpty {
            add(separator(id: "sep:recents"))
            extra.forEach(add)
        }

        add(separator(id: "sep:others"))
        for tile in prefs.persistentOthers {
            guard let url = tile.url else { continue }
            let kind: DockItemKind
            switch tile.type {
            case "directory-tile": kind = .folder
            case "url-tile": kind = .url
            default: kind = url.isFileURL && Self.isFolder(url) ? .folder : (url.isFileURL ? .file : .url)
            }
            add(DockItem(id: "", kind: kind, title: tile.label, url: url))
        }
        add(DockItem(id: "", kind: .trash, title: "Papirkurv"))
        return items
    }

    // MARK: - Hjelpere

    private func separator(id: String) -> DockItem {
        DockItem(id: id, kind: .separator, title: "")
    }

    private func uniqueID(for item: DockItem, used: inout [String: Int]) -> String {
        if !item.id.isEmpty { return item.id }
        let base = "\(item.kind):\(item.url.map(DockItem.key(for:)) ?? item.title)"
        let n = used[base, default: 0]
        used[base] = n + 1
        return n == 0 ? base : "\(base)#\(n)"
    }

    private func bundleIdentifier(for url: URL) -> String? {
        let key = url.path
        if let cached = bundleIDs[key] { return cached.isEmpty ? nil : cached }
        let id = Bundle(url: url)?.bundleIdentifier
        bundleIDs[key] = id ?? ""
        return id
    }

    static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}
