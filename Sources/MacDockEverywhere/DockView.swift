import AppKit

/// Tegner én kopi av Docken og håndterer mus, forstørrelse, auto-skjul og dra-og-slipp.
final class DockView: NSView {
    unowned let controller: DockController
    var onGlassChange: ((NSRect?, CGFloat) -> Void)?

    private(set) var items: [DockItem] = []
    private(set) var prefs = DockPreferences()
    private(set) var metrics = DockMetrics(prefs: DockPreferences())
    var orientation: DockOrientation { prefs.orientation }

    /// Tvinger auto-skjul (fullskjermsapp på denne skjermen), slik den ekte Docken gjør.
    var forcedAutohide = false {
        didSet { if forcedAutohide != oldValue { autohideChanged() } }
    }
    private var autohideEnabled: Bool { prefs.autohide || forcedAutohide }

    /// Satt mens en meny eller stabel er åpen fra denne kopien.
    var popupOpen = false {
        didSet { invalidate(); scheduleTick() }
    }

    private struct Tile {
        var center: CGFloat
        var width: CGFloat
        var scale: CGFloat
    }

    private struct Layout {
        var tiles: [Tile]
        var start: CGFloat
        var end: CGFloat
    }

    private struct Bounce {
        var start: CFTimeInterval
        var end: CFTimeInterval?
    }

    private var layout = Layout(tiles: [], start: 0, end: 0)
    private var pointerInside = false
    private var pointerU: CGFloat = 0
    private var magnify: CGFloat = 0
    private var hoverIndex: Int?

    private var pressedIndex: Int?
    private var longPressTimer: Timer?
    private var longPressFired = false

    private var dropIndex: Int?
    private var draggingInside = false

    private var hiddenAmount: CGFloat = 0
    private var hideTarget: CGFloat = 0
    private var edgeArrival: CFTimeInterval?
    private var leftAt: CFTimeInterval?

    private var bounces: [String: Bounce] = [:]
    private let bouncePeriod: CFTimeInterval = 0.6

    private var ticker: Timer?
    private var tickerInterval: TimeInterval?
    /// Lytter etter musebevegelser når Docken er skjult, i stedet for å spørre hele tiden.
    private var mouseMonitor: Any?
    private var lastPointerMove: CFTimeInterval = 0
    /// Nye kopier starter i hvile til vinduet faktisk vises.
    private var isSuspended = true
    private var lastTick = CACurrentMediaTime()
    private var lastDirty = NSRect.zero

    init(controller: DockController) {
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Oppdatering

    func update(items: [DockItem], prefs: DockPreferences) {
        let itemsChanged = items != self.items
        let prefsChanged = prefs != self.prefs
        let autohideWas = autohideEnabled
        // Indekser følger elementet (ikke posisjonen) når listen endrer seg.
        let hoverID = hoverIndex.flatMap { $0 < self.items.count ? self.items[$0].id : nil }
        let pressedID = pressedIndex.flatMap { $0 < self.items.count ? self.items[$0].id : nil }
        self.items = items
        if prefsChanged {
            self.prefs = prefs
            metrics = DockMetrics(prefs: prefs)
            if autohideWas != autohideEnabled { autohideChanged() }
        }
        if itemsChanged {
            hoverIndex = hoverID.flatMap { id in items.firstIndex { $0.id == id } }
            pressedIndex = pressedID.flatMap { id in items.firstIndex { $0.id == id } }
            dropIndex = nil
            if pressedIndex == nil { longPressTimer?.invalidate() }
        }
        if itemsChanged || prefsChanged { invalidate() }
    }

    func startBounce(_ id: String) {
        guard prefs.launchAnimation, bounces[id] == nil else { return }
        bounces[id] = Bounce(start: CACurrentMediaTime(), end: nil)
        scheduleTick()
    }

    private func autohideChanged() {
        hideTarget = autohideEnabled ? 1 : 0
        edgeArrival = nil
        leftAt = nil
        if !autohideEnabled { hiddenAmount = 0 }
        updateMouseMonitor()
        invalidate()
        scheduleTick()
    }

    /// Stopper all animasjon og lytting (vinduet er skjult eller appen hviler).
    func suspend() {
        isSuspended = true
        longPressTimer?.invalidate()
        pointerInside = false
        hoverIndex = nil
        pressedIndex = nil
        dropIndex = nil
        draggingInside = false
        ticker?.invalidate()
        ticker = nil
        tickerInterval = nil
        updateMouseMonitor()
    }

    func resume() {
        isSuspended = false
        updateMouseMonitor()
        scheduleTick()
    }

    private func updateMouseMonitor() {
        let wanted = autohideEnabled && !isSuspended
        if wanted, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
                self?.globalMouseMoved()
            }
        } else if !wanted, let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    /// Når Docken er skjult, våkner vi bare når pekeren treffer skjermkanten.
    private func globalMouseMoved() {
        guard hideTarget > 0.5, edgeArrival == nil, atScreenEdge(NSEvent.mouseLocation) else { return }
        edgeArrival = CACurrentMediaTime()
        scheduleTick()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidate()
    }

    func invalidate() {
        layout = computeLayout()
        let bar = barRect()
        onGlassChange?(items.isEmpty || easedHidden >= 0.999 ? nil : bar, metrics.cornerRadius)
        let dirty = contentRect()
        setNeedsDisplay(dirty.union(lastDirty))
        lastDirty = dirty
    }

    // MARK: - Geometri

    private var axisLength: CGFloat { orientation == .bottom ? bounds.width : bounds.height }

    private var easedHidden: CGFloat { hiddenAmount * hiddenAmount * (3 - 2 * hiddenAmount) }

    private var slide: CGFloat { easedHidden * (metrics.edgeGap + metrics.bar + 6) }

    /// Rektangel i "dock-koordinater": u langs Docken, v ut fra skjermkanten.
    private func rect(u: CGFloat, v: CGFloat, du: CGFloat, dv: CGFloat) -> NSRect {
        let v = v - slide
        switch orientation {
        case .bottom: return NSRect(x: u, y: v, width: du, height: dv)
        case .left: return NSRect(x: v, y: bounds.height - u - du, width: dv, height: du)
        case .right: return NSRect(x: bounds.width - v - dv, y: bounds.height - u - du, width: dv, height: du)
        }
    }

    private func dockPoint(_ p: NSPoint) -> (u: CGFloat, v: CGFloat) {
        switch orientation {
        case .bottom: return (p.x, p.y + slide)
        case .left: return (bounds.height - p.y, p.x + slide)
        case .right: return (bounds.height - p.y, bounds.width - p.x + slide)
        }
    }

    private func computeLayout() -> Layout {
        let m = metrics
        let widths = items.map { m.width(of: $0.kind) }
        let total = widths.reduce(0, +) + 2 * m.padding
        let start = ((axisLength - total) / 2).rounded()
        var centers: [CGFloat] = []
        var x = start + m.padding
        for w in widths {
            centers.append(x + w / 2)
            x += w
        }
        let maxExtra = m.large / m.tile - 1
        guard magnify > 0.001, maxExtra > 0.001, !items.isEmpty else {
            return Layout(tiles: zip(centers, widths).map { Tile(center: $0, width: $1, scale: 1) },
                          start: start, end: start + total)
        }

        let pointer = min(max(pointerU, start + m.padding), start + total - m.padding - 0.01)
        let range = m.pitch * 3.2
        let scales = centers.map { c -> CGFloat in
            let d = abs(c - pointer) / range
            guard d < 1 else { return 1 }
            return 1 + magnify * maxExtra * (cos(d * .pi) + 1) / 2
        }
        let scaled = zip(widths, scales).map { $0 * $1 }
        var k = 0
        for (i, c) in centers.enumerated() where pointer >= c - widths[i] / 2 { k = i }
        let fraction = min(max((pointer - (centers[k] - widths[k] / 2)) / widths[k], 0), 1)
        var starts: [CGFloat] = []
        var acc: CGFloat = 0
        for w in scaled {
            starts.append(acc)
            acc += w
        }
        // Punktet under pekeren står stille mens ikonene rundt vokser.
        let shift = pointer - (starts[k] + fraction * scaled[k])
        let tiles = scaled.indices.map { Tile(center: shift + starts[$0] + scaled[$0] / 2, width: scaled[$0], scale: scales[$0]) }
        return Layout(tiles: tiles, start: shift - m.padding, end: shift + acc + m.padding)
    }

    private func barRect() -> NSRect {
        rect(u: layout.start, v: metrics.edgeGap, du: layout.end - layout.start, dv: metrics.bar)
    }

    /// Dock-linjen slik den står når den er synlig (uavhengig av auto-skjul).
    func restingBarRect() -> NSRect {
        rect(u: layout.start, v: metrics.edgeGap + slide, du: layout.end - layout.start, dv: metrics.bar)
    }

    /// Området som kan endre seg (Docken + navnelapp), for effektiv omtegning.
    private func contentRect() -> NSRect {
        let margin: CGFloat = 260
        switch orientation {
        case .bottom:
            return NSRect(x: layout.start - margin, y: 0, width: layout.end - layout.start + 2 * margin, height: bounds.height)
        case .left, .right:
            return NSRect(x: 0, y: bounds.height - layout.end - margin, width: bounds.width,
                          height: layout.end - layout.start + 2 * margin)
        }
    }

    private func iconSize(_ tile: Tile) -> CGFloat { metrics.tile * tile.scale }

    func iconRect(at index: Int) -> NSRect {
        guard index < layout.tiles.count else { return .zero }
        let tile = layout.tiles[index]
        let size = iconSize(tile)
        return rect(u: tile.center - size / 2, v: metrics.iconBase, du: size, dv: size)
    }

    func screenRect(forItemAt index: Int) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(iconRect(at: index), to: nil))
    }

    private func reach(of tile: Tile) -> CGFloat {
        max(metrics.edgeGap + metrics.bar, metrics.iconBase + iconSize(tile))
    }

    private func index(atU u: CGFloat, v: CGFloat) -> Int? {
        guard u >= layout.start, u <= layout.end, v >= -2 else { return nil }
        for (i, tile) in layout.tiles.enumerated()
        where u >= tile.center - tile.width / 2 && u < tile.center + tile.width / 2 {
            return v <= reach(of: tile) ? i : nil
        }
        return nil
    }

    private func isOverDock(u: CGFloat, v: CGFloat) -> Bool {
        guard !items.isEmpty, easedHidden < 0.98, u >= layout.start, u <= layout.end, v >= -2 else { return false }
        if v <= metrics.edgeGap + metrics.bar { return true }
        return index(atU: u, v: v) != nil
    }

    private func index(at event: NSEvent) -> Int? {
        let p = dockPoint(convert(event.locationInWindow, from: nil))
        guard let i = index(atU: p.u, v: p.v), items[i].isSelectable else { return nil }
        return i
    }

    // MARK: - Peker og animasjon

    private func pointerLocation() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    private func refreshPointer() {
        guard let p = pointerLocation() else { return }
        let d = dockPoint(p)
        let inside = bounds.contains(p) && isOverDock(u: d.u, v: d.v)
        var hover: Int?
        if inside {
            if pointerU != d.u {
                lastPointerMove = CACurrentMediaTime()
                if prefs.magnification {
                    pointerU = d.u
                    invalidate()
                }
            }
            pointerU = d.u
            if let i = index(atU: d.u, v: d.v), items[i].isSelectable { hover = i }
        }
        if inside != pointerInside || hover != hoverIndex {
            pointerInside = inside
            hoverIndex = hover
            invalidate()
        }
    }

    /// 60 Hz bare mens noe animeres, 15 Hz mens vi bare følger pekeren, ellers ingen tidtaker.
    private func scheduleTick() {
        let magnifyTarget: CGFloat = prefs.magnification && (pointerInside || popupOpen || draggingInside) ? 1 : 0
        let pointerMoving = magnify > 0.001 && CACurrentMediaTime() - lastPointerMove < 0.25
        let animating = magnify != magnifyTarget || pointerMoving || !bounces.isEmpty
            || abs(hiddenAmount - hideTarget) > 0.0001
        // Når pekeren står stille over Docken holder det å se etter at den forlater den.
        let watching = pointerInside || pressedIndex != nil || popupOpen || draggingInside
            || (autohideEnabled && (hideTarget < 0.5 || edgeArrival != nil))
        var interval: TimeInterval? = animating ? 1.0 / 60 : (watching ? 1.0 / 10 : nil)
        if isSuspended || window?.isVisible != true { interval = nil }
        if interval == tickerInterval, ticker != nil || interval == nil { return }
        ticker?.invalidate()
        ticker = nil
        tickerInterval = interval
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        lastTick = CACurrentMediaTime()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        refreshPointer()

        var changed = false
        let magnifyTarget: CGFloat = prefs.magnification && (pointerInside || popupOpen || draggingInside) ? 1 : 0
        if magnify != magnifyTarget {
            let step = CGFloat(dt / 0.15)
            magnify = magnifyTarget > magnify ? min(magnifyTarget, magnify + step) : max(magnifyTarget, magnify - step)
            changed = true
        }
        if updateAutohide(now: now, dt: dt) { changed = true }
        if updateBounces(now: now) { changed = true }
        if changed { invalidate() }
        scheduleTick()
    }

    private func atScreenEdge(_ mouse: NSPoint) -> Bool {
        guard let f = window?.screen?.frame else { return false }
        switch orientation {
        case .bottom: return mouse.y <= f.minY + 1 && mouse.x >= f.minX && mouse.x < f.maxX
        case .left: return mouse.x <= f.minX + 1 && mouse.y >= f.minY && mouse.y < f.maxY
        case .right: return mouse.x >= f.maxX - 2 && mouse.y >= f.minY && mouse.y < f.maxY
        }
    }

    private func updateAutohide(now: CFTimeInterval, dt: CFTimeInterval) -> Bool {
        guard autohideEnabled else {
            guard hiddenAmount != 0 else { return false }
            hiddenAmount = 0
            hideTarget = 0
            return true
        }
        let mouse = NSEvent.mouseLocation
        if hideTarget > 0.5 {
            if draggingInside {
                hideTarget = 0
            } else if atScreenEdge(mouse) {
                if edgeArrival == nil { edgeArrival = now }
                if let arrival = edgeArrival, now - arrival >= prefs.autohideDelay {
                    hideTarget = 0
                    edgeArrival = nil
                }
            } else {
                edgeArrival = nil
            }
            leftAt = nil
        } else {
            if pointerInside || popupOpen || draggingInside || pressedIndex != nil || atScreenEdge(mouse) {
                leftAt = nil
            } else {
                if leftAt == nil { leftAt = now }
                if let left = leftAt, now - left > 0.25 {
                    hideTarget = 1
                    edgeArrival = nil
                }
            }
        }
        guard hiddenAmount != hideTarget else { return false }
        let duration = 0.5 * prefs.autohideTimeModifier
        if duration <= 0.01 {
            hiddenAmount = hideTarget
        } else {
            let step = CGFloat(dt / duration)
            hiddenAmount = hideTarget > hiddenAmount ? min(hideTarget, hiddenAmount + step) : max(hideTarget, hiddenAmount - step)
        }
        return true
    }

    private func updateBounces(now: CFTimeInterval) -> Bool {
        guard !bounces.isEmpty else { return false }
        for (id, bounce) in bounces {
            if bounce.end == nil, !controller.isLaunching(id: id, in: items) {
                let cycles = max(1, ((now - bounce.start) / bouncePeriod).rounded(.up))
                bounces[id]?.end = bounce.start + cycles * bouncePeriod
            }
            if let end = bounces[id]?.end, now >= end { bounces[id] = nil }
        }
        return true
    }

    private func bounceLift(for id: String, now: CFTimeInterval) -> CGFloat {
        guard let bounce = bounces[id] else { return 0 }
        let p = ((now - bounce.start) / bouncePeriod).truncatingRemainder(dividingBy: 1)
        return metrics.bounceHeight * CGFloat(4 * p * (1 - p))
    }

    // MARK: - Tegning

    private static let labelBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.17, alpha: 0.94) : NSColor(white: 0.98, alpha: 0.94)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty, easedHidden < 0.999 else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        let m = metrics
        let now = CACurrentMediaTime()
        drawRim()

        for (i, item) in items.enumerated() where i < layout.tiles.count {
            let tile = layout.tiles[i]
            switch item.kind {
            case .spacer:
                continue
            case .separator:
                let length = (m.bar * 0.75).rounded()
                let line = rect(u: tile.center - 0.5, v: m.edgeGap + (m.bar - length) / 2, du: 1, dv: length)
                NSColor.labelColor.withAlphaComponent(0.95).setFill()
                backingAlignedRect(line, options: .alignAllEdgesNearest).fill()
            default:
                let size = iconSize(tile)
                let iconRect = rect(u: tile.center - size / 2, v: m.iconBase + bounceLift(for: item.id, now: now),
                                    du: size, dv: size)
                if let image = IconProvider.shared.icon(for: item, prefs: prefs) {
                    drawIcon(image, in: iconRect, darkened: pressedIndex == i || dropIndex == i)
                }
                if let progress = item.progress { drawProgress(progress, icon: iconRect) }
                if let badge = item.badge { drawBadge(badge, icon: iconRect) }
                if prefs.showProcessIndicators, item.isRunning, item.kind == .application {
                    let d = m.dot
                    let dot = rect(u: tile.center - d / 2, v: m.edgeGap + m.dotOffset - d / 2, du: d, dv: d)
                    NSColor.labelColor.withAlphaComponent(0.85).setFill()
                    NSBezierPath(ovalIn: dot).fill()
                }
            }
        }

        if let h = hoverIndex, h < items.count, h < layout.tiles.count, !popupOpen, dropIndex == nil {
            drawLabel(items[h].title, tile: layout.tiles[h])
        }
    }

    /// Glasskanten slik den ekte Docken har den: lys refleks langs langsidene, mørk hårlinje på endene.
    private func drawRim() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bar = barRect()
        let r = min(metrics.cornerRadius, bar.height / 2, bar.width / 2)
        let path = CGPath(roundedRect: bar, cornerWidth: r, cornerHeight: r, transform: nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // Masken går på tvers av Docken: sterk ved langsidene, borte på midten.
        let (start, end): (CGPoint, CGPoint) = orientation == .bottom
            ? (CGPoint(x: 0, y: bar.minY), CGPoint(x: 0, y: bar.maxY))
            : (CGPoint(x: bar.minX, y: 0), CGPoint(x: bar.maxX, y: 0))

        func masked(_ edgesBright: Bool, _ draw: () -> Void) {
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            draw()
            context.setBlendMode(.destinationIn)
            let a: CGFloat = edgesBright ? 1 : 0, b: CGFloat = edgesBright ? 0 : 1
            let colors = [CGColor(gray: 0, alpha: a), CGColor(gray: 0, alpha: b), CGColor(gray: 0, alpha: b),
                          CGColor(gray: 0, alpha: a)] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.35, 0.65, 1]) {
                context.drawLinearGradient(gradient, start: start, end: end, options: [])
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }

        masked(true) {
            context.addPath(path)
            context.clip()
            for (width, alpha) in [(6.0, 0.05), (3.0, 0.05), (2.0, 0.2), (1.0, 0.35)] as [(CGFloat, CGFloat)] {
                context.addPath(path)
                context.setLineWidth(width)
                context.setStrokeColor(CGColor(gray: 1, alpha: alpha))
                context.strokePath()
            }
        }
        masked(false) {
            context.addPath(CGPath(roundedRect: bar.insetBy(dx: -0.25, dy: -0.25), cornerWidth: r + 0.25,
                                   cornerHeight: r + 0.25, transform: nil))
            context.setLineWidth(0.5)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.75))
            context.strokePath()
        }
    }

    private func drawIcon(_ image: NSImage, in rect: NSRect, darkened: Bool) {
        guard darkened, let context = NSGraphicsContext.current?.cgContext else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.black.withAlphaComponent(0.4).setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
    }

    private func drawProgress(_ value: Double, icon: NSRect) {
        let h = max(4, (icon.height * 0.12).rounded())
        let track = NSRect(x: icon.minX + icon.width * 0.1, y: icon.minY + icon.height * 0.1, width: icon.width * 0.8, height: h)
        NSColor(white: 0.12, alpha: 0.75).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        var fill = track.insetBy(dx: 1, dy: 1)
        fill.size.width = max(fill.height, fill.width * CGFloat(value))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }

    private func drawBadge(_ text: String, icon: NSRect) {
        let d = icon.width * 0.4
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: d * 0.56, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let textSize = attributed.size()
        let width = max(d, textSize.width + d * 0.6)
        let centerX = icon.minX + icon.width * 0.82
        let centerY = icon.maxY - icon.height * 0.19
        let badge = NSRect(x: centerX + d / 2 - width, y: centerY - d / 2, width: width, height: d)
        NSColor(srgbRed: 0.93, green: 0.27, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: badge, xRadius: d / 2, yRadius: d / 2).fill()
        attributed.draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2))
    }

    private func drawLabel(_ text: String, tile: Tile) {
        guard !text.isEmpty else { return }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        let textSize = attributed.size()
        let w = ceil(textSize.width) + 22
        let h = ceil(textSize.height) + 9
        let anchor = rect(u: tile.center, v: metrics.iconBase + iconSize(tile) + 9, du: 0, dv: 0)
        var label: NSRect
        switch orientation {
        case .bottom: label = NSRect(x: anchor.minX - w / 2, y: anchor.minY, width: w, height: h)
        case .left: label = NSRect(x: anchor.minX, y: anchor.minY - h / 2, width: w, height: h)
        case .right: label = NSRect(x: anchor.minX - w, y: anchor.minY - h / 2, width: w, height: h)
        }
        label.origin.x = min(max(label.minX, bounds.minX + 4), bounds.maxX - w - 4)
        label = label.integral

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        let path = NSBezierPath(roundedRect: label, xRadius: h / 2, yRadius: h / 2)
        Self.labelBackground.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        attributed.draw(at: NSPoint(x: label.midX - textSize.width / 2, y: label.midY - textSize.height / 2))
    }

    // MARK: - Mus

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved() }
    override func mouseMoved(with event: NSEvent) { pointerMoved() }
    override func mouseExited(with event: NSEvent) { pointerMoved() }

    private func pointerMoved() {
        refreshPointer()
        scheduleTick()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
            return
        }
        guard let i = index(at: event) else { return }
        pressedIndex = i
        longPressFired = false
        longPressTimer?.invalidate()
        let id = items[i].id
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self, let current = self.pressedIndex, self.items[current].id == id else { return }
            self.longPressFired = true
            self.pressedIndex = nil
            self.showMenu(for: current)
        }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
        invalidate()
        scheduleTick()
    }

    override func mouseUp(with event: NSEvent) {
        longPressTimer?.invalidate()
        guard let i = pressedIndex else { return }
        pressedIndex = nil
        invalidate()
        guard !longPressFired, i < items.count, index(at: event) == i else { return }
        controller.activate(items[i], modifiers: event.modifierFlags, view: self, index: i)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        showMenu(for: i)
    }

    private func showMenu(for index: Int) {
        guard index < items.count, items[index].isSelectable else { return }
        let item = items[index]
        popupOpen = true
        controller.menuProvider.menu(for: item) { [weak self] menu in
            guard let self else { return }
            guard let menu, let i = self.items.firstIndex(where: { $0.id == item.id }) else {
                self.popupOpen = false
                return
            }
            self.popUp(menu, anchorIndex: i)
        }
    }

    /// Viser en meny over (eller ved siden av) et ikon, slik Docken gjør.
    func popUp(_ menu: NSMenu, anchorIndex: Int) {
        popupOpen = true
        let anchor = iconRect(at: anchorIndex)
        let size = menu.size
        let gap: CGFloat = 12
        let location: NSPoint
        switch orientation {
        case .bottom: location = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap + size.height)
        case .left: location = NSPoint(x: anchor.maxX + gap, y: anchor.midY + size.height / 2)
        case .right: location = NSPoint(x: anchor.minX - gap - size.width, y: anchor.midY + size.height / 2)
        }
        menu.popUp(positioning: nil, at: location, in: self)
        popupOpen = false
        refreshPointer()
    }

    // MARK: - Dra og slipp

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingInside = true
        scheduleTick()
        return draggingUpdated(sender)
    }

    /// Elementet under pekeren og operasjonen det godtar akkurat nå.
    private func dropTarget(_ sender: NSDraggingInfo) -> (index: Int, operation: NSDragOperation)? {
        let p = dockPoint(convert(sender.draggingLocation, from: nil))
        pointerU = p.u
        guard let i = index(atU: p.u, v: p.v) else { return nil }
        let operation = controller.dropOperation(for: items[i], sender)
        return operation.isEmpty ? nil : (i, operation)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = dropTarget(sender)
        if target?.index != dropIndex {
            dropIndex = target?.index
            invalidate()
        }
        return target?.operation ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        endDrag()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        endDrag()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endDrag() }
        // Regnes ut på nytt ved slipp: listen kan ha endret seg siden forrige draggingUpdated.
        guard let target = dropTarget(sender) else { return false }
        return controller.performDrop(on: items[target.index], sender, operation: target.operation)
    }

    private func endDrag() {
        guard dropIndex != nil || draggingInside else { return }
        dropIndex = nil
        draggingInside = false
        invalidate()
        scheduleTick()
    }
}
