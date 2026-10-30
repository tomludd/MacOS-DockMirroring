import AppKit

/// Holder styr på den ekte Docken og viser en kopi på hver skjerm som ikke har den.
final class DockController: NSObject {
    private(set) var prefs = DockPreferences.load()
    private(set) var items: [DockItem] = []
    let menuProvider = DockMenuProvider()
    let stacks = StackPresenter()

    private var panels: [CGDirectDisplayID: DockPanel] = [:]
    private var dockDisplay: CGDirectDisplayID?
    private var fullscreen: Set<CGDirectDisplayID> = []

    private let reader = DockReader()
    private let sampler = BackdropSampler()
    private let readQueue = DispatchQueue(label: "dockeverywhere.reader", qos: .userInitiated)
    private let actionQueue = DispatchQueue(label: "dockeverywhere.actions", qos: .userInteractive)
    private var reading = false
    private var readAgain = false

    private var launchOrder: [NSRunningApplication] = []
    /// Bundle-ID-er (eller stier) for apper som er i ferd med å starte.
    private var launching: Set<String> = []
    private var timers: [Timer] = []

    /// Appen gjør ingenting (ingen tidtakere, ingen avlesning) med bare én skjerm eller når skjermene sover.
    private(set) var isActive = false
    private var screensAsleep = false

    /// Kan overstyres for testing: `open … --args -minimumDisplays 3`.
    private var minimumDisplays: Int { max(2, UserDefaults.standard.integer(forKey: "minimumDisplays")) }

    func start() {
        WindowThumbnails.shared.onUpdate = { [weak self] in
            self?.panels.values.forEach { $0.dockView.invalidate() }
        }
        launchOrder = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appWillLaunch(_:)), name: NSWorkspace.willLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appDidLaunch(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appDidTerminate(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspace.addObserver(self, selector: #selector(workspaceChanged), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screensDidSleep), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screensDidWake), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerStateChanged),
                                               name: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(powerStateChanged),
                                               name: PowerSource.didChange, object: nil)
        PowerSource.startObserving()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(preferencesMayHaveChanged),
                                                            name: NSNotification.Name("com.apple.dock.prefchanged"), object: nil)
        updateActivity()
    }

    // MARK: - Aktiv / hvile

    /// Starter eller stopper alt arbeid ut fra hvor mange skjermer som er tilkoblet.
    private func updateActivity() {
        let shouldRun = NSScreen.screens.count >= minimumDisplays && !screensAsleep
        guard shouldRun != isActive else { return }
        isActive = shouldRun
        if shouldRun {
            prefs = DockPreferences.load()
            startTimers()
            updatePanels()
            updateFullscreen()
            refreshItems()
        } else {
            stopTimers()
            stacks.close()
            for panel in panels.values {
                panel.dockView.suspend()
                panel.orderOut(nil)
            }
            panels.removeAll()
            items = []
            WindowThumbnails.shared.clear()
        }
    }

    /// Den gjenværende lette avlesningen (hvilken skjerm Docken står på, og innholdet) går
    /// sjeldnere på batteri og i strømsparingsmodus. App-start/-avslutning m.m. er hendelsesstyrt.
    private func startTimers() {
        stopTimers()
        let saving = ProcessInfo.processInfo.isLowPowerModeEnabled || PowerSource.isOnBattery
        repeatEvery(saving ? 1.0 : 0.5) { [weak self] in self?.updatePanels() }
        repeatEvery(saving ? 4.0 : 2.0) { [weak self] in self?.refreshItems() }
        repeatEvery(15) { [weak self] in self?.reloadPreferences() }
        if ScreenCapture.isEnabled { repeatEvery(120) { [weak self] in self?.updateGlass() } }
    }

    private func stopTimers() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
    }

    private func repeatEvery(_ interval: TimeInterval, _ block: @escaping () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in block() }
        // Romslig toleranse lar macOS samle oppvåkninger og sparer strøm.
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    @objc private func screensDidSleep() {
        screensAsleep = true
        updateActivity()
    }

    @objc private func screensDidWake() {
        screensAsleep = false
        updateActivity()
    }

    @objc private func powerStateChanged() {
        DispatchQueue.main.async {
            if self.isActive { self.startTimers() }
        }
    }

    /// Kalles når Skjermopptak slås av eller på i menyen.
    func screenCaptureSettingChanged() {
        if isActive { startTimers() }
        if !ScreenCapture.isEnabled { WindowThumbnails.shared.clear() }
        updateGlass()
        refreshItems()
    }

    // MARK: - Skjermer

    /// Viser kopier på alle skjermer unntatt den der den ekte Docken står.
    private func updatePanels() {
        guard isActive else { return }
        let screens = NSScreen.screens
        let current = ScreenLocator.dockDisplayID() ?? dockDisplay ?? NSScreen.screens.first?.displayID
        dockDisplay = current

        let ids = Set(screens.map(\.displayID))
        for (id, panel) in panels where !ids.contains(id) {
            panel.dockView.suspend()
            panel.orderOut(nil)
            panels[id] = nil
        }
        for screen in screens {
            let id = screen.displayID
            let panel: DockPanel
            if let existing = panels[id] {
                panel = existing
            } else {
                panel = DockPanel(screen: screen, controller: self)
                panel.dockView.update(items: items, prefs: prefs)
                panel.dockView.forcedAutohide = fullscreen.contains(id)
                panels[id] = panel
            }
            if id == current {
                if panel.isVisible {
                    if stacks.isShowing(from: panel.dockView) { stacks.close() }
                    panel.dockView.suspend()
                    panel.orderOut(nil)
                }
            } else {
                panel.place()
                if !panel.isVisible {
                    panel.orderFrontRegardless()
                    panel.dockView.resume()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak panel] in
                        if let panel { self?.updateGlass(panel) }
                    }
                }
            }
        }
    }

    @objc private func screensChanged() {
        updateActivity()
        guard isActive else { return }
        updatePanels()
        panels.values.forEach { $0.place() }
        updateFullscreen()
        updateGlass()
    }

    @objc private func spaceChanged() {
        guard isActive else { return }
        refreshItems()
        // Fullskjermsapper får egne skrivebord, så her er det nok å sjekke.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.updateFullscreen()
            self.updateGlass()
        }
    }

    @objc private func appActivated() {
        guard isActive else { return }
        runningCache = nil
        refreshItems()
        updateFullscreen()
    }

    /// Velger lyst eller mørkt glass for hver kopi, som den ekte Docken.
    func updateGlass(_ only: DockPanel? = nil) {
        for panel in only.map({ [$0] }) ?? Array(panels.values) where panel.isVisible {
            switch GlassMode.current {
            case .light: panel.setGlass(dark: false)
            case .dark: panel.setGlass(dark: true)
            case .automatic:
                guard ScreenCapture.isAvailable, let rect = panel.barRectInDisplay() else {
                    panel.setGlass(dark: nil)
                    continue
                }
                sampler.isDark(displayID: panel.displayID, rect: rect) { [weak panel] dark in
                    panel?.setGlass(dark: dark)
                }
            }
        }
    }

    private func updateFullscreen() {
        guard isActive else { return }
        let now = ScreenLocator.fullscreenDisplayIDs()
        guard now != fullscreen else { return }
        fullscreen = now
        for (id, panel) in panels { panel.dockView.forcedAutohide = now.contains(id) }
    }

    // MARK: - Innhold

    func refreshItems() {
        guard isActive else { return }
        if reading {
            readAgain = true
            return
        }
        reading = true
        let prefs = self.prefs
        let running = runningApps()
        let dockPID = ScreenLocator.dockPID
        let reader = self.reader
        readQueue.async {
            let items = reader.read(dockPID: dockPID, prefs: prefs, running: running)
            DispatchQueue.main.async {
                self.reading = false
                self.apply(items)
                if self.readAgain {
                    self.readAgain = false
                    self.refreshItems()
                }
            }
        }
    }

    /// Mellomlagret, fordi `activationPolicy` spør LaunchServices hver gang.
    private var runningCache: (apps: [RunningAppInfo], time: Date)?

    private func runningApps() -> [RunningAppInfo] {
        if let cache = runningCache, Date().timeIntervalSince(cache.time) < 10 { return cache.apps }
        let apps = loadRunningApps()
        runningCache = (apps, Date())
        return apps
    }

    private func loadRunningApps() -> [RunningAppInfo] {
        let all = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !$0.isTerminated }
        let known = Set(launchOrder.map(\.processIdentifier))
        let ordered = launchOrder.filter { app in all.contains { $0.processIdentifier == app.processIdentifier } }
            + all.filter { !known.contains($0.processIdentifier) }
        return ordered.map {
            RunningAppInfo(pid: $0.processIdentifier, url: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier,
                           name: $0.localizedName ?? "")
        }
    }

    private func apply(_ newItems: [DockItem]) {
        guard isActive else { return }
        items = newItems
        WindowThumbnails.shared.refresh(newItems)
        for panel in panels.values {
            panel.dockView.update(items: newItems, prefs: prefs)
            for item in newItems where isLaunching(item) { panel.dockView.startBounce(item.id) }
        }
    }

    private func reloadPreferences() {
        guard isActive else { return }
        let loaded = DockPreferences.load()
        guard loaded != prefs else { return }
        prefs = loaded
        for panel in panels.values {
            panel.dockView.update(items: items, prefs: prefs)
            panel.place()
        }
        refreshItems()
    }

    @objc private func preferencesMayHaveChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.reloadPreferences() }
    }

    @objc private func workspaceChanged() {
        runningCache = nil
        refreshItems()
    }

    // MARK: - Oppstart av apper (hopp-animasjon)

    private func launchKey(bundleID: String?, url: URL?) -> String? {
        bundleID ?? url.map(DockItem.key(for:))
    }

    func isLaunching(_ item: DockItem) -> Bool {
        guard item.kind == .application else { return false }
        if let id = item.bundleIdentifier, launching.contains(id) { return true }
        if let url = item.url, launching.contains(DockItem.key(for: url)) { return true }
        return false
    }

    func isLaunching(id: String, in items: [DockItem]) -> Bool {
        items.first { $0.id == id }.map(isLaunching) ?? false
    }

    private func markLaunching(bundleID: String?, url: URL?) {
        guard let key = launchKey(bundleID: bundleID, url: url) else { return }
        launching.insert(key)
        if isActive { apply(items) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.launching.remove(key) }
    }

    @objc private func appWillLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        markLaunching(bundleID: app.bundleIdentifier, url: app.bundleURL)
        runningCache = nil
        refreshItems()
    }

    @objc private func appDidLaunch(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if let key = launchKey(bundleID: app.bundleIdentifier, url: app.bundleURL) { launching.remove(key) }
        if !launchOrder.contains(app) { launchOrder.append(app) }
        runningCache = nil
        refreshItems()
    }

    @objc private func appDidTerminate(_ note: Notification) {
        if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            launchOrder.removeAll { $0 == app }
            if let key = launchKey(bundleID: app.bundleIdentifier, url: app.bundleURL) { launching.remove(key) }
        }
        runningCache = nil
        refreshItems()
    }

    /// Testmodus: åpner høyreklikk-menyen for et element i første synlige kopi.
    func debugShowMenu(title: String) -> DockView? {
        guard let panel = panels.values.first(where: { $0.isVisible }),
              let index = panel.dockView.items.firstIndex(where: { $0.title == title }) else { return nil }
        panel.dockView.showMenu(for: index)
        return panel.dockView
    }

    // MARK: - Klikk

    func activate(_ item: DockItem, modifiers: NSEvent.ModifierFlags, view: DockView, index: Int) {
        if item.kind != .folder { stacks.close() }
        // Cmd-Option-klikk på en app skjuler alle andre; bare Cmd viser i Finder.
        let hideOthers = item.kind == .application && modifiers.contains([.command, .option])
        if !hideOthers, modifiers.contains(.command), item.kind != .minimizedWindow, let url = item.url, url.isFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        switch item.kind {
        case .application:
            let previous = NSWorkspace.shared.frontmostApplication
            if !item.isRunning { markLaunching(bundleID: item.bundleIdentifier, url: item.url) }
            press(item) { [weak self] ok in
                if !ok { self?.openApplication(item) }
            }
            if modifiers.contains(.option) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if modifiers.contains(.command) {
                        for app in NSWorkspace.shared.runningApplications
                        where app.activationPolicy == .regular && app.bundleIdentifier != item.bundleIdentifier {
                            app.hide()
                        }
                    } else if let previous, previous.bundleIdentifier != item.bundleIdentifier {
                        previous.hide()
                    }
                }
            }
        case .folder:
            guard let url = item.url else { return }
            stacks.toggle(folder: url, title: item.title, settings: prefs.folderSettings(for: url), view: view, index: index)
        case .trash:
            press(item) { ok in
                if !ok, let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
                    NSWorkspace.shared.open(trash)
                }
            }
        case .file, .url:
            press(item) { ok in
                if !ok, let url = item.url { NSWorkspace.shared.open(url) }
            }
        case .minimizedWindow:
            press(item) { _ in }
        case .separator, .spacer:
            break
        }
    }

    /// Klikker på det samme elementet i den ekte Docken, slik at oppførselen blir identisk.
    private func press(_ item: DockItem, completion: @escaping (Bool) -> Void) {
        guard let element = item.axElement, AX.isTrusted else {
            completion(false)
            return
        }
        actionQueue.async {
            let ok = AX.perform(element, kAXPressAction)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    private func openApplication(_ item: DockItem) {
        guard let url = item.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    // MARK: - Dra og slipp

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func shouldCopy(_ urls: [URL], into folder: URL) -> Bool {
        if NSEvent.modifierFlags.contains(.option) { return true }
        let target = (try? folder.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        return urls.contains { url in
            let volume = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
            return volume == nil || target == nil || !volume!.isEqual(target)
        }
    }

    /// Operasjonen et element godtar, begrenset til det kilden tillater.
    func dropOperation(for item: DockItem, _ info: NSDraggingInfo) -> NSDragOperation {
        let urls = fileURLs(info)
        let allowed = info.draggingSourceOperationMask
        guard !urls.isEmpty else { return [] }
        switch item.kind {
        case .application:
            guard item.url != nil else { return [] }
            return [NSDragOperation.generic, .copy, .link].first { allowed.contains($0) } ?? []
        case .folder:
            guard let folder = item.url else { return [] }
            if !shouldCopy(urls, into: folder), allowed.contains(.move) { return .move }
            return allowed.contains(.copy) ? .copy : []
        case .trash:
            return allowed.contains(.move) ? .move : []
        default:
            return []
        }
    }

    func performDrop(on item: DockItem, _ info: NSDraggingInfo, operation: NSDragOperation) -> Bool {
        let urls = fileURLs(info)
        guard !urls.isEmpty, !operation.isEmpty else { return false }
        switch item.kind {
        case .application:
            guard let app = item.url else { return false }
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return true
        case .folder:
            guard let folder = item.url else { return false }
            FileDrops.move(urls, into: folder, copy: operation == .copy)
            return true
        case .trash:
            FileDrops.trash(urls)
            return true
        default:
            return false
        }
    }
}

/// Filoperasjoner for slipp i Docken. Kjøres i bakgrunnen så store kopier ikke fryser Docken.
enum FileDrops {
    private static let queue = DispatchQueue(label: "dockeverywhere.files", qos: .userInitiated)

    static func move(_ urls: [URL], into folder: URL, copy: Bool) {
        queue.async {
            let ok = transfer(urls, into: folder, copy: copy)
            if !ok { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    private static func transfer(_ urls: [URL], into folder: URL, copy: Bool) -> Bool {
        let fm = FileManager.default
        var ok = true
        for source in urls {
            let src = source.standardizedFileURL
            let dst = folder.standardizedFileURL
            if src.deletingLastPathComponent() == dst || dst.path == src.path || dst.path.hasPrefix(src.path + "/") { continue }
            var target = dst.appendingPathComponent(src.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                let ext = src.pathExtension
                let base = src.deletingPathExtension().lastPathComponent
                target = dst.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            do {
                if copy { try fm.copyItem(at: src, to: target) } else { try fm.moveItem(at: src, to: target) }
            } catch {
                // En avbrutt kopi skal ikke etterlate en halv fil (originalen er urørt).
                if copy { try? fm.removeItem(at: target) }
                ok = false
            }
        }
        return ok
    }

    static func trash(_ urls: [URL]) {
        queue.async {
            var ok = true
            var trashed = false
            for url in urls {
                do {
                    if (try? url.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true {
                        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    } else {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                        trashed = true
                    }
                } catch {
                    ok = false
                }
            }
            DispatchQueue.main.async {
                if !ok {
                    NSSound.beep()
                } else if trashed {
                    NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif",
                            byReference: true)?.play()
                }
            }
        }
    }
}
