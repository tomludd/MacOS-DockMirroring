import AppKit

/// Gjennomsiktig vindu på Dock-nivå langs kanten av én skjerm.
/// Klikk i de gjennomsiktige delene går rett gjennom til vinduene bak.
final class DockPanel: NSPanel {
    let displayID: CGDirectDisplayID
    let dockView: DockView
    private let glass: NSView

    init(screen: NSScreen, controller: DockController) {
        displayID = screen.displayID
        dockView = DockView(controller: controller)
        if #available(macOS 26.0, *) {
            // Målt mot den ekte Docken: «klart» glass gir samme farge og gjennomsiktighet.
            let view = NSGlassEffectView()
            view.style = .clear
            glass = view
        } else {
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            view.wantsLayer = true
            view.layer?.masksToBounds = true
            glass = view
        }
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true

        let container = NSView()
        container.wantsLayer = true
        glass.isHidden = true
        container.addSubview(glass)
        container.addSubview(dockView)
        contentView = container
        dockView.autoresizingMask = [.width, .height]
        dockView.onGlassChange = { [weak self] rect, radius in self?.updateGlass(rect, radius: radius) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var screenForPanel: NSScreen? { NSScreen.screens.first { $0.displayID == displayID } }

    /// Plasserer vinduet langs riktig skjermkant ut fra Dock-innstillingene.
    func place() {
        guard let frame = targetFrame() else { return }
        guard self.frame != frame else { return }
        setFrame(frame, display: true)
        if let content = contentView { dockView.frame = content.bounds }
        dockView.invalidate()
    }

    /// `nil` følger systemets utseende.
    func setGlass(dark: Bool?) {
        let appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? nil
        if glass.appearance?.name != appearance?.name { glass.appearance = appearance }
        if #available(macOS 26.0, *), let view = glass as? NSGlassEffectView {
            // Målt mot den ekte Docken over mørk bakgrunn (#505050).
            let isDark = dark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            view.tintColor = isDark ? NSColor(white: 1, alpha: 0.07) : nil
        }
    }

    private func targetFrame() -> NSRect? {
        guard let screen = screenForPanel else { return nil }
        let f = screen.frame
        let thickness = dockView.metrics.thickness(for: dockView.orientation)
        switch dockView.orientation {
        case .bottom: return NSRect(x: f.minX, y: f.minY, width: f.width, height: thickness)
        case .left: return NSRect(x: f.minX, y: f.minY, width: thickness, height: f.height)
        case .right: return NSRect(x: f.maxX - thickness, y: f.minY, width: thickness, height: f.height)
        }
    }

    /// Hvor Dock-linjen står (uten auto-skjul), relativt til skjermen med origo øverst til venstre.
    /// Regnes ut fra skjermen, ikke fra vinduet, siden vinduet kan være midt i en flytting.
    func barRectInDisplay() -> CGRect? {
        guard let screen = screenForPanel, let panel = targetFrame() else { return nil }
        let bar = dockView.restingBarRect().offsetBy(dx: panel.minX, dy: panel.minY)
        return CGRect(x: bar.minX - screen.frame.minX, y: screen.frame.maxY - bar.maxY, width: bar.width, height: bar.height)
    }

    private func updateGlass(_ rect: NSRect?, radius: CGFloat) {
        guard let rect else {
            glass.isHidden = true
            return
        }
        glass.isHidden = false
        if glass.frame != rect { glass.frame = rect }
        if #available(macOS 26.0, *), let view = glass as? NSGlassEffectView {
            if view.cornerRadius != radius { view.cornerRadius = radius }
        } else {
            glass.layer?.cornerRadius = radius
        }
    }
}
