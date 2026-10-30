import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Finner ut hvilken skjerm den ekte Docken står på, og hvilke skjermer som viser en fullskjermsapp.
enum ScreenLocator {
    private static var cachedDock: NSRunningApplication?
    private static let lock = NSLock()

    static var dockPID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        if let dock = cachedDock, !dock.isTerminated { return dock.processIdentifier }
        cachedDock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        return cachedDock?.processIdentifier
    }

    private static var dockWindowID: CGWindowID?

    /// Dock-vinduet ligger på nivå `kCGDockWindowLevel` og dekker skjermen Docken står på.
    static func dockDisplayID() -> CGDirectDisplayID? {
        // Rask vei: slå opp bare det kjente Dock-vinduet.
        if let id = dockWindowID, let window = describe(id), let display = dockDisplay(of: window) { return display }
        dockWindowID = nil
        for options: CGWindowListOption in [.optionOnScreenOnly, .optionAll] {
            guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { continue }
            for window in list {
                if let display = dockDisplay(of: window) {
                    dockWindowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                    return display
                }
            }
        }
        return nil
    }

    private static func describe(_ id: CGWindowID) -> [String: Any]? {
        let values = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
        defer { values.deallocate() }
        values[0] = UnsafeRawPointer(bitPattern: UInt(id))
        guard let array = CFArrayCreate(nil, values, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return nil }
        return list.first
    }

    private static func dockDisplay(of window: [String: Any]) -> CGDirectDisplayID? {
        guard let dockPID,
              (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dockPID,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == Int(CGWindowLevelForKey(.dockWindow)),
              let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: bounds.midX, y: bounds.midY), 1, &display, &count)
        return count > 0 ? display : nil
    }

    /// Skjermer der et vindu på vanlig nivå dekker hele skjermen (fullskjermsapp).
    static func fullscreenDisplayIDs() -> Set<CGDirectDisplayID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = NSScreen.screens.map { ($0.displayID, CGDisplayBounds($0.displayID)) }
        var result = Set<CGDirectDisplayID>()
        for window in list {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            for (id, displayBounds) in displays where bounds.equalTo(displayBounds) {
                result.insert(id)
            }
        }
        return result
    }
}
