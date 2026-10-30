import AppKit

/// Viser innholdet i en mappe fra Docken som vifte, rutenett eller liste – som den ekte Docken.
final class StackPresenter: NSObject, NSMenuDelegate {
    private var panel: NSPanel?
    private var folder: URL?
    private weak var view: DockView?
    private var monitors: [Any] = []

    func isShowing(from view: DockView) -> Bool { panel != nil && self.view === view }

    func toggle(folder: URL, title: String, settings: FolderTileSettings, view: DockView, index: Int) {
        if panel != nil, self.folder == folder {
            close()
            return
        }
        close()
        let entries = FolderContents.list(folder, arrangement: settings.arrangement)
        var mode = settings.showAs
        if mode == 0 { mode = entries.count <= 10 ? 1 : 2 }
        if mode == 1, view.orientation != .bottom { mode = 2 }
        if mode == 3 {
            view.popUp(listMenu(for: folder, entries: entries, includeOpen: true), anchorIndex: index)
            return
        }
        guard let screen = view.window?.screen else { return }
        let anchor = view.screenRect(forItemAt: index)

        let content: StackContentView
        if mode == 1 {
            content = FanView(folder: folder, entries: entries, maxHeight: screen.visibleFrame.height - anchor.height - 40)
        } else {
            content = GridView(folder: folder, title: title, entries: entries, arrangement: settings.arrangement)
        }
        content.onOpen = { [weak self] url in
            NSWorkspace.shared.open(url)
            self?.close()
        }
        content.onDragOut = { [weak self] in self?.close() }
        content.onResize = { [weak self, weak content] in
            guard let self, let content, let panel = self.panel else { return }
            panel.setFrame(self.frame(for: content, anchor: anchor, screen: screen, orientation: view.orientation), display: true)
        }

        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = mode != 1
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = content
        let frame = frame(for: content, anchor: anchor, screen: screen, orientation: view.orientation)
        panel.setFrame(frame, display: false)
        if let fan = content as? FanView { fan.anchorX = anchor.midX - frame.minX }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        self.panel = panel
        self.folder = folder
        self.view = view
        view.popupOpen = true
        installMonitors()
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        folder = nil
        view?.popupOpen = false
        view = nil
    }

    private func frame(for content: StackContentView, anchor: NSRect, screen: NSScreen, orientation: DockOrientation) -> NSRect {
        let size = content.preferredSize
        let visible = screen.visibleFrame
        var origin: NSPoint
        switch orientation {
        case .bottom: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 10)
        case .left: origin = NSPoint(x: anchor.maxX + 10, y: anchor.midY - size.height / 2)
        case .right: origin = NSPoint(x: anchor.minX - 10 - size.width, y: anchor.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        return NSRect(origin: origin, size: size)
    }

    private func installMonitors() {
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in self?.close() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            guard let self else { return event }
            // Venstreklikk i Docken håndteres av klikket selv (lukker eller bytter stabel).
            let inDock = event.window is DockPanel && event.type == .leftMouseDown
            if event.window !== self.panel, !inDock { self.close() }
            return event
        }) {
            monitors.append(local)
        }
        if let keys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { self?.close() }
        }) {
            monitors.append(keys)
        }
    }

    // MARK: - Listevisning (meny)

    private func listMenu(for folder: URL, entries: [FolderContents.Entry], includeOpen: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries.prefix(500) {
            let item: NSMenuItem
            if entry.isFolder {
                item = NSMenuItem(title: entry.name, action: nil, keyEquivalent: "")
                let sub = NSMenu(title: entry.url.path)
                sub.delegate = self
                item.submenu = sub
            } else {
                let url = entry.url
                item = ClosureMenuItem(entry.name) { NSWorkspace.shared.open(url) }
            }
            let icon = NSWorkspace.shared.icon(forFile: entry.url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if includeOpen {
            if !entries.isEmpty { menu.addItem(.separator()) }
            menu.addItem(ClosureMenuItem("Åpne i Finder") { NSWorkspace.shared.open(folder) })
        }
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.items.isEmpty else { return }
        let folder = URL(fileURLWithPath: menu.title)
        let filled = listMenu(for: folder, entries: FolderContents.list(folder, arrangement: 1), includeOpen: true)
        for item in filled.items {
            filled.removeItem(item)
            menu.addItem(item)
        }
    }
}

// MARK: - Felles for vifte og rutenett

class StackContentView: NSView, NSDraggingSource {
    var onOpen: ((URL) -> Void)?
    var onResize: (() -> Void)?
    /// Et element ble dratt ut av stabelen; stabelen lukkes.
    var onDragOut: (() -> Void)?
    var preferredSize: NSSize { .zero }

    private var icons: [URL: NSImage] = [:]
    private var mouseDownPoint: NSPoint?
    private var mouseDownURL: URL?

    func icon(for url: URL) -> NSImage {
        if let icon = icons[url] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url] = icon
        return icon
    }

    /// URL-en og ikonrammen under et punkt.
    func hit(_ point: NSPoint) -> (url: URL, iconRect: NSRect)? { nil }

    /// Om elementet under punktet kan dras ut (knapper kan ikke).
    func canDrag(at point: NSPoint) -> Bool { hit(point) != nil }

    func activate(_ url: URL) { onOpen?(url) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        mouseDownURL = hit(p)?.url
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, let url = mouseDownURL, canDrag(at: start), let hit = hit(start) else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(hit.iconRect, contents: icon(for: url))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            mouseDownURL = nil
        }
        guard mouseDownPoint != nil, let url = mouseDownURL,
              hit(convert(event.locationInWindow, from: nil))?.url == url else { return }
        activate(url)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if !operation.isEmpty { onDragOut?() }
    }
}

// MARK: - Vifte

final class FanView: StackContentView {
    private let folder: URL
    private let entries: [FolderContents.Entry]
    private let hiddenCount: Int
    var anchorX: CGFloat = 0 { didSet { needsDisplay = true } }
    private var hover: Int?

    private let rowHeight: CGFloat = 54
    private let iconSize: CGFloat = 48
    private let buttonHeight: CGFloat = 40
    private let width: CGFloat = 640

    init(folder: URL, entries: [FolderContents.Entry], maxHeight: CGFloat) {
        self.folder = folder
        let fit = max(1, Int((maxHeight - 60) / 54))
        let shown = Array(entries.prefix(min(fit, 15)))
        self.entries = shown
        hiddenCount = entries.count - shown.count
        super.init(frame: .zero)
        anchorX = width / 2
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredSize: NSSize {
        NSSize(width: width, height: CGFloat(entries.count) * rowHeight + buttonHeight + 16)
    }

    /// Hver rad følger en svak bue mot høyre og vippes litt, som viften i Docken.
    private func transform(for row: Int) -> AffineTransform {
        let i = CGFloat(row)
        var t = AffineTransform(translationByX: anchorX + 0.42 * i * i, byY: 6 + rowHeight * i + rowHeight / 2)
        t.rotate(byDegrees: -1.1 * i)
        return t
    }

    private func labelRect(for entry: FolderContents.Entry) -> (NSRect, NSAttributedString) {
        let text = NSAttributedString(string: entry.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let w = min(ceil(size.width) + 20, 260)
        let h = ceil(size.height) + 6
        return (NSRect(x: -iconSize / 2 - 8 - w, y: -h / 2, width: w, height: h), text)
    }

    private var buttonTitle: String {
        hiddenCount > 0 ? "\(hiddenCount) til i Finder" : "Åpne i Finder"
    }

    private func buttonRect() -> NSRect {
        let text = NSAttributedString(string: buttonTitle, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        let w = ceil(text.size().width) + 28
        let top = transform(for: entries.count).transform(NSPoint.zero)
        return NSRect(x: top.x - w / 2, y: top.y - rowHeight / 2 + 6, width: w, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        for (row, entry) in entries.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            (transform(for: row) as NSAffineTransform).concat()
            let (labelRect, text) = labelRect(for: entry)
            let pill = NSBezierPath(roundedRect: labelRect, xRadius: labelRect.height / 2, yRadius: labelRect.height / 2)
            (hover == row ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.62)).setFill()
            pill.fill()
            text.draw(with: labelRect.insetBy(dx: 10, dy: 3), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
            icon(for: entry.url).draw(in: NSRect(x: -iconSize / 2, y: -iconSize / 2, width: iconSize, height: iconSize))
            NSGraphicsContext.restoreGraphicsState()
        }

        let button = buttonRect()
        let path = NSBezierPath(roundedRect: button, xRadius: button.height / 2, yRadius: button.height / 2)
        (hover == -1 ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.62)).setFill()
        path.fill()
        let text = NSAttributedString(string: buttonTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: button.midX - size.width / 2, y: button.midY - size.height / 2))
    }

    private func row(at point: NSPoint) -> Int? {
        if buttonRect().contains(point) { return -1 }
        for row in entries.indices {
            var inverse = transform(for: row)
            inverse.invert()
            let p = inverse.transform(point)
            let iconRect = NSRect(x: -iconSize / 2, y: -iconSize / 2, width: iconSize, height: iconSize)
            if iconRect.contains(p) || labelRect(for: entries[row]).0.contains(p) { return row }
        }
        return nil
    }

    override func canDrag(at point: NSPoint) -> Bool {
        guard let row = row(at: point) else { return false }
        return row >= 0
    }

    override func hit(_ point: NSPoint) -> (url: URL, iconRect: NSRect)? {
        guard let row = row(at: point) else { return nil }
        if row == -1 { return (folder, buttonRect()) }
        let center = transform(for: row).transform(NSPoint.zero)
        return (entries[row].url, NSRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2, width: iconSize, height: iconSize))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row != hover {
            hover = row
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }
}

// MARK: - Rutenett

final class GridView: StackContentView {
    private var folder: URL
    private var title: String
    private var entries: [FolderContents.Entry]
    private let arrangement: Int
    private var history: [(URL, String)] = []

    private let glass: NSView
    private let scroll = NSScrollView()
    private let grid = GridDocumentView()
    private let header = NSTextField(labelWithString: "")
    private let back = NSButton()
    private let openButton = NSButton()

    private let cell = NSSize(width: 96, height: 104)
    private let columnsMax = 7
    private let rowsVisible = 4

    init(folder: URL, title: String, entries: [FolderContents.Entry], arrangement: Int) {
        self.folder = folder
        self.title = title
        self.entries = entries
        self.arrangement = arrangement
        if #available(macOS 26.0, *) {
            let view = NSGlassEffectView()
            view.cornerRadius = 22
            glass = view
        } else {
            let view = NSVisualEffectView()
            view.material = .popover
            view.state = .active
            view.wantsLayer = true
            view.layer?.cornerRadius = 22
            view.layer?.masksToBounds = true
            glass = view
        }
        super.init(frame: .zero)

        addSubview(glass)
        header.font = .systemFont(ofSize: 15, weight: .semibold)
        header.alignment = .center
        header.lineBreakMode = .byTruncatingMiddle
        addSubview(header)

        back.bezelStyle = .accessoryBarAction
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Tilbake")
        back.isBordered = false
        back.target = self
        back.action = #selector(goBack)
        addSubview(back)

        openButton.title = "Åpne i Finder"
        openButton.bezelStyle = .push
        openButton.controlSize = .regular
        openButton.target = self
        openButton.action = #selector(openInFinder)
        addSubview(openButton)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        addSubview(scroll)

        grid.owner = self
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var columns: Int { max(1, min(entries.count, columnsMax)) }
    private var rows: Int { max(1, Int(ceil(Double(entries.count) / Double(columns)))) }

    override var preferredSize: NSSize {
        NSSize(width: max(CGFloat(columns) * cell.width + 32, 300),
               height: CGFloat(min(rows, rowsVisible)) * cell.height + 44 + 48 + 8)
    }

    private func reload() {
        header.stringValue = title
        back.isHidden = history.isEmpty
        grid.entries = entries
        grid.columns = columns
        grid.cell = cell
        needsLayout = true
        onResize?()
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let gridWidth = CGFloat(columns) * cell.width
        header.frame = NSRect(x: 40, y: bounds.height - 36, width: bounds.width - 80, height: 22)
        back.frame = NSRect(x: 12, y: bounds.height - 38, width: 26, height: 26)
        openButton.sizeToFit()
        openButton.frame.origin = NSPoint(x: (bounds.width - openButton.frame.width) / 2, y: 12)
        scroll.frame = NSRect(x: (bounds.width - gridWidth) / 2 - 8, y: 52, width: gridWidth + 16, height: bounds.height - 52 - 44)
        grid.frame = NSRect(x: 0, y: 0, width: gridWidth + 16, height: CGFloat(rows) * cell.height)
    }

    override func activate(_ url: URL) {
        if let entry = entries.first(where: { $0.url == url }), entry.isFolder {
            history.append((folder, title))
            folder = url
            title = entry.name
            entries = FolderContents.list(url, arrangement: arrangement)
            reload()
            return
        }
        super.activate(url)
    }

    @objc private func goBack() {
        guard let (url, name) = history.popLast() else { return }
        folder = url
        title = name
        entries = FolderContents.list(url, arrangement: arrangement)
        reload()
    }

    @objc private func openInFinder() {
        onOpen?(folder)
    }

    override func hit(_ point: NSPoint) -> (url: URL, iconRect: NSRect)? {
        guard scroll.frame.contains(point) else { return nil }
        let p = grid.convert(point, from: self)
        guard grid.visibleRect.contains(p), let hit = grid.hit(p) else { return nil }
        return (hit.url, convert(hit.iconRect, from: grid))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        grid.hover = hit(point) == nil ? nil : grid.hit(grid.convert(point, from: self))?.index
    }

    override func mouseExited(with event: NSEvent) {
        grid.hover = nil
    }
}

final class GridDocumentView: NSView {
    weak var owner: GridView?
    var entries: [FolderContents.Entry] = [] { didSet { needsDisplay = true } }
    var columns = 1
    var cell = NSSize(width: 96, height: 104)
    var hover: Int? { didSet { if hover != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func cellRect(_ index: Int) -> NSRect {
        NSRect(x: 8 + CGFloat(index % columns) * cell.width, y: CGFloat(index / columns) * cell.height,
               width: cell.width, height: cell.height)
    }

    private func iconRect(_ index: Int) -> NSRect {
        let c = cellRect(index)
        return NSRect(x: c.midX - 32, y: c.minY + 8, width: 64, height: 64)
    }

    func hit(_ point: NSPoint) -> (index: Int, url: URL, iconRect: NSRect)? {
        guard point.x >= 8, point.y >= 0 else { return nil }
        let column = Int((point.x - 8) / cell.width)
        let row = Int(point.y / cell.height)
        let index = row * columns + column
        guard column < columns, index >= 0, index < entries.count else { return nil }
        return (index, entries[index].url, iconRect(index))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        for index in entries.indices {
            let c = cellRect(index)
            guard c.intersects(dirtyRect) else { continue }
            if hover == index {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: c.insetBy(dx: 4, dy: 2), xRadius: 10, yRadius: 10).fill()
            }
            let entry = entries[index]
            (owner?.icon(for: entry.url) ?? NSWorkspace.shared.icon(forFile: entry.url.path))
                .draw(in: iconRect(index), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let name = NSAttributedString(string: entry.name, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
            name.draw(with: NSRect(x: c.minX + 4, y: c.minY + 76, width: c.width - 8, height: 28),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // Klikk og dra håndteres av GridView (StackContentView).
    override func mouseDown(with event: NSEvent) { owner?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp(with: event) }
}
