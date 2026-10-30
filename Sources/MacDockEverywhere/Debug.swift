import AppKit
import ApplicationServices
import ScreenCaptureKit

/// Feilsøking: `open MacDockEverywhere.app --args --dump-ax /sti/til/fil.txt`
/// skriver Dock-strukturen slik Tilgjengelighet-API-et ser den.
enum Debug {
    /// Resultat fra en bakgrunnsoppgave (skrives før semaforen signaleres, leses etterpå).
    private final class Box: @unchecked Sendable {
        var text = ""
    }

    static func handleArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--dump-ax"), i + 1 < args.count {
            dumpDock(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--dump-state"), i + 1 < args.count {
            dumpState(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--dump-menu"), i + 2 < args.count {
            dumpMenu(title: args[i + 1], to: args[i + 2])
            exit(0)
        }
    }

    /// `--show-menu <tittel> <fil>`: åpner kopiens høyreklikk-meny, skriver hvor menyen og ikonet
    /// står (skjermkoordinater, origo øverst til venstre), lukker menyen og avslutter.
    static func runMenuTestIfRequested(controller: DockController) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--show-menu"), i + 2 < args.count else { return }
        let title = args[i + 1], path = args[i + 2]
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let view = controller.debugShowMenu(title: title) else {
                try? "fant ikke \(title)\n".write(toFile: path, atomically: true, encoding: .utf8)
                exit(1)
            }
            let timer = Timer(timeInterval: 2, repeats: false) { _ in
                var out = ""
                let pid = ProcessInfo.processInfo.processIdentifier
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                for window in list where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid {
                    let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
                    if let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                       let rect = CGRect(dictionaryRepresentation: bounds) {
                        out += "vindu nivå \(layer): \(rect)\n"
                    }
                }
                if let index = view.items.firstIndex(where: { $0.title == title }), let screen = NSScreen.screens.first {
                    let icon = view.screenRect(forItemAt: index)
                    out += "ikon: \(CGRect(x: icon.minX, y: screen.frame.maxY - icon.maxY, width: icon.width, height: icon.height))\n"
                }
                try? out.write(toFile: path, atomically: true, encoding: .utf8)
                view.trackingMenu?.cancelTracking()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private static func describe(_ value: CFTypeRef?) -> String {
        guard let value else { return "nil" }
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return "<element>" }
        if let array = value as? [AnyObject] { return "[\(array.count) items]" }
        return String(describing: value).replacingOccurrences(of: "\n", with: " ")
    }

    private static func dump(_ element: AXUIElement, depth: Int, maxDepth: Int, into out: inout String) {
        let indent = String(repeating: "  ", count: depth)
        out += "\(indent)- \(AX.role(element) ?? "?") / \(AX.subrole(element) ?? "-")\n"
        for name in AX.attributeNames(element) where ![kAXChildrenAttribute, kAXParentAttribute, kAXTopLevelUIElementAttribute,
                                                         kAXWindowAttribute].contains(name) {
            out += "\(indent)    \(name) = \(describe(AX.value(element, name)))\n"
        }
        let actions = AX.actionNames(element)
        if !actions.isEmpty { out += "\(indent)    actions: \(actions.joined(separator: ", "))\n" }
        guard depth < maxDepth else { return }
        for child in AX.children(element) { dump(child, depth: depth + 1, maxDepth: maxDepth, into: &out) }
    }

    static func dumpDock(to path: String) {
        var out = "trusted: \(AX.isTrusted)\n"
        if let pid = ScreenLocator.dockPID {
            dump(AXUIElementCreateApplication(pid), depth: 0, maxDepth: 2, into: &out)
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func dumpState(to path: String) {
        var out = "ax: \(AX.isTrusted) screenCapture: \(ScreenCapture.isEnabled)/\(ScreenCapture.hasPermission)\n"
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map {
            RunningAppInfo(pid: $0.processIdentifier, url: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier,
                           name: $0.localizedName ?? "")
        }
        for app in running {
            let axApp = AXUIElementCreateApplication(app.pid)
            let windows = AX.elements(axApp, kAXWindowsAttribute)
            let minimized = windows.filter { AX.bool($0, kAXMinimizedAttribute) == true }.map { AX.title($0) ?? "?" }
            if !minimized.isEmpty { out += "\(app.name): \(windows.count) vinduer, minimert: \(minimized)\n" }
        }
        let items = DockReader().read(dockPID: ScreenLocator.dockPID, prefs: DockPreferences.load(), running: running)
        for item in items where item.kind == .minimizedWindow {
            out += "dock: \(item.title) -> pid \(item.ownerPID.map(String.init) ?? "nil") \(item.url?.lastPathComponent ?? "")\n"
        }
        let semaphore = DispatchSemaphore(value: 0)
        let result = Box()
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                result.text = "SCK ok: \(content.windows.count) vinduer\n"
            } catch {
                result.text = "SCK feil: \(error)\n"
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        out += result.text
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func dumpMenu(title: String, to path: String) {
        var out = ""
        if let pid = ScreenLocator.dockPID,
           let list = AX.children(AXUIElementCreateApplication(pid)).first(where: { AX.role($0) == kAXListRole }),
           let item = AX.children(list).first(where: { AX.title($0) == title }) {
            let start = Date()
            out += "show: \(AX.perform(item, kAXShowMenuAction)) after \(Date().timeIntervalSince(start))s\n"
            usleep(300_000)
            dump(item, depth: 0, maxDepth: 4, into: &out)
            if let menu = AX.children(item).first(where: { AX.role($0) == kAXMenuRole }) {
                for entry in AX.children(menu) {
                    let primary = AX.value(entry, "AXMenuItemPrimaryUIElement")
                    let alternate = primary.map { !CFEqual($0, entry) } ?? false
                    out += "item: \(AX.title(entry) ?? "") alternate=\(alternate)\n"
                }
                out += "cancel: \(AX.perform(menu, kAXCancelAction))\n"
            }
        } else {
            out += "fant ikke \(title)\n"
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Enkel logg til ~/Library/Logs/DockEverywhere.log (for feilsøking).
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DockEverywhere.log")
    private static let queue = DispatchQueue(label: "dockeverywhere.log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
