import AppKit
import UniformTypeIdentifiers

/// Lager og cacher ikonene som vises i kopiene.
final class IconProvider {
    static let shared = IconProvider()

    private var fileIcons: [String: NSImage] = [:]
    private var stacks: [String: (stamp: Date?, checked: Date, image: NSImage)] = [:]
    private var calendar: (day: String, image: NSImage)?
    private var minimized: [String: NSImage] = [:]

    func icon(for item: DockItem, prefs: DockPreferences) -> NSImage? {
        switch item.kind {
        case .application:
            if item.bundleIdentifier == "com.apple.iCal" { return calendarIcon() }
            return fileIcon(item.url) ?? NSWorkspace.shared.icon(for: .application)
        case .folder:
            guard let url = item.url else { return NSWorkspace.shared.icon(for: .folder) }
            let settings = prefs.folderSettings(for: url)
            return settings.displayAs == 1 ? fileIcon(url) : stackIcon(url, arrangement: settings.arrangement)
        case .file:
            return fileIcon(item.url) ?? NSWorkspace.shared.icon(for: .data)
        case .url:
            if let url = item.url, url.isFileURL { return fileIcon(url) }
            return NSWorkspace.shared.icon(for: UTType("com.apple.web-internet-location") ?? .url)
        case .trash:
            return trashIcon(full: prefs.trashFull)
        case .minimizedWindow:
            return minimizedIcon(item)
        case .separator, .spacer:
            return nil
        }
    }

    func fileIcon(_ url: URL?) -> NSImage? {
        guard let url, url.isFileURL else { return nil }
        let key = url.path
        if let cached = fileIcons[key] { return cached }
        guard FileManager.default.fileExists(atPath: key) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: key)
        fileIcons[key] = image
        return image
    }

    // MARK: Papirkurv

    private lazy var trashEmpty = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/TrashIcon.icns")
        ?? NSImage(named: NSImage.trashEmptyName)
    private lazy var trashFull = NSImage(contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FullTrashIcon.icns")
        ?? NSImage(named: NSImage.trashFullName)

    private func trashIcon(full: Bool) -> NSImage? { full ? trashFull : trashEmpty }

    // MARK: Kalender (viser dagens dato, som i Docken)

    private lazy var weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.preferredLanguages.first ?? "en")
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()

    private func calendarIcon() -> NSImage {
        let now = Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let key = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        if let calendar, calendar.day == key { return calendar.image }
        let dayName = weekdayFormatter.string(from: now).replacingOccurrences(of: ".", with: "")
        let dayNumber = String(parts.day ?? 1)

        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let s = rect.width
            let body = rect.insetBy(dx: s * 0.095, dy: s * 0.095)
            let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = s * 0.012
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
            shadow.set()
            NSColor.white.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()

            let red = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
            let top = NSAttributedString(string: dayName, attributes: [
                .font: NSFont.systemFont(ofSize: s * 0.135, weight: .semibold),
                .foregroundColor: red,
            ])
            let topSize = top.size()
            top.draw(at: NSPoint(x: rect.midX - topSize.width / 2, y: body.maxY - s * 0.06 - topSize.height))

            let number = NSAttributedString(string: dayNumber, attributes: [
                .font: NSFont.systemFont(ofSize: s * 0.44, weight: .regular),
                .foregroundColor: NSColor(white: 0.12, alpha: 1),
            ])
            let numberSize = number.size()
            number.draw(at: NSPoint(x: rect.midX - numberSize.width / 2, y: body.minY + s * 0.05))
            return true
        }
        calendar = (key, image)
        return image
    }

    // MARK: Mappestabler

    func stackIcon(_ folder: URL, arrangement: Int) -> NSImage {
        let key = folder.path + "#\(arrangement)"
        // Tegnes ofte (f.eks. ved forstørrelse), så mappen sjekkes høyst hvert 3. sekund.
        if let cached = stacks[key], Date().timeIntervalSince(cached.checked) < 3 { return cached.image }
        let stamp = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = stacks[key], cached.stamp == stamp {
            stacks[key] = (stamp, Date(), cached.image)
            return cached.image
        }

        let entries = FolderContents.list(folder, arrangement: arrangement).prefix(3)
        let image: NSImage
        if entries.isEmpty {
            image = NSWorkspace.shared.icon(forFile: folder.path)
        } else {
            let icons = entries.map { NSWorkspace.shared.icon(forFile: $0.url.path) }
            image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
                let step = rect.width * 0.045
                for (depth, icon) in icons.enumerated().reversed() {
                    let inset = rect.width * 0.04 * CGFloat(depth)
                    var r = rect.insetBy(dx: inset, dy: inset)
                    r.origin.x -= step * CGFloat(depth)
                    r.origin.y += step * CGFloat(depth)
                    icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: depth == 0 ? 1 : 0.92)
                }
                return true
            }
        }
        stacks[key] = (stamp, Date(), image)
        return image
    }

    // MARK: Minimerte vinduer

    private func minimizedIcon(_ item: DockItem) -> NSImage {
        if let thumbnail = WindowThumbnails.shared.thumbnail(for: item) { return thumbnail }
        let key = item.url?.path ?? "?"
        if let cached = minimized[key] { return cached }
        let appIcon = fileIcon(item.url)
        let image = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let s = rect.width
            let window = NSRect(x: s * 0.03, y: s * 0.2, width: s * 0.94, height: s * 0.62)
            let path = NSBezierPath(roundedRect: window, xRadius: s * 0.04, yRadius: s * 0.04)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
            shadow.shadowBlurRadius = s * 0.02
            shadow.set()
            NSColor(white: 0.97, alpha: 1).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            let titleBar = NSRect(x: window.minX, y: window.maxY - s * 0.09, width: window.width, height: s * 0.09)
            NSColor(white: 0.9, alpha: 1).setFill()
            NSBezierPath(roundedRect: titleBar, xRadius: s * 0.04, yRadius: s * 0.04).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                let d = s * 0.035
                NSBezierPath(ovalIn: NSRect(x: window.minX + s * 0.03 + CGFloat(i) * d * 1.6,
                                            y: titleBar.midY - d / 2, width: d, height: d)).fill()
            }
            appIcon?.draw(in: NSRect(x: s * 0.6, y: s * 0.08, width: s * 0.38, height: s * 0.38))
            return true
        }
        minimized[key] = image
        return image
    }
}

/// Leser innholdet i en mappe, sortert slik Docken gjør det.
enum FolderContents {
    struct Entry {
        let url: URL
        let name: String
        let isFolder: Bool
    }

    static func list(_ folder: URL, arrangement: Int) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey,
                                      .contentModificationDateKey, .creationDateKey, .localizedNameKey,
                                      .localizedTypeDescriptionKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return [] }
        struct Row { let entry: Entry; let values: URLResourceValues? }
        let rows = urls.map { url -> Row in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = v?.isDirectory == true && v?.isPackage != true
            return Row(entry: Entry(url: url, name: v?.localizedName ?? url.lastPathComponent, isFolder: isFolder), values: v)
        }
        let byName: (Row, Row) -> Bool = { $0.entry.name.localizedStandardCompare($1.entry.name) == .orderedAscending }
        func byDate(_ key: @escaping (URLResourceValues?) -> Date?) -> (Row, Row) -> Bool {
            { (key($0.values) ?? .distantPast) > (key($1.values) ?? .distantPast) }
        }
        let sorted: [Row]
        switch arrangement {
        case 2: sorted = rows.sorted(by: byDate { $0?.addedToDirectoryDate })
        case 3: sorted = rows.sorted(by: byDate { $0?.contentModificationDate })
        case 4: sorted = rows.sorted(by: byDate { $0?.creationDate })
        case 5: sorted = rows.sorted {
            let a = $0.values?.localizedTypeDescription ?? "", b = $1.values?.localizedTypeDescription ?? ""
            return a == b ? byName($0, $1) : a.localizedStandardCompare(b) == .orderedAscending
        }
        default: sorted = rows.sorted(by: byName)
        }
        return sorted.map(\.entry)
    }
}
