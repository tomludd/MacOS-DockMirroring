import AppKit

/// Mål målt fra den ekte Docken (macOS 26/27), skalert etter ikonstørrelsen.
struct DockMetrics {
    let tile: CGFloat
    let pitch: CGFloat
    let separator: CGFloat
    let bar: CGFloat
    let edgeGap: CGFloat
    let padding: CGFloat
    let large: CGFloat
    let cornerRadius: CGFloat
    let dot: CGFloat
    let dotOffset: CGFloat
    let bounceHeight: CGFloat
    let labelSpace: CGFloat

    init(prefs: DockPreferences) {
        let t = prefs.tileSize
        let k = t / 35
        tile = t
        pitch = 37 * k
        separator = 16.65 * k
        bar = (48 * k).rounded()
        edgeGap = 6
        padding = 3.35 * k
        large = prefs.magnification ? max(prefs.largeSize, t) : t
        cornerRadius = (bar * 0.3).rounded()
        dot = max(3, (4 * k).rounded())
        dotOffset = 5 * k
        bounceHeight = t * 0.65
        labelSpace = 48
    }

    /// Avstand fra skjermkanten til bunnen av ikonene.
    var iconBase: CGFloat { edgeGap + (bar - tile) / 2 }

    /// Tykkelsen på vinduet (inkl. plass til forstørrelse, hopp og navnelapp).
    func thickness(for orientation: DockOrientation) -> CGFloat {
        let label: CGFloat = orientation == .bottom ? labelSpace : 260
        return (iconBase + max(large, tile + bounceHeight) + label).rounded(.up)
    }

    func width(of kind: DockItemKind) -> CGFloat { kind == .separator ? separator : pitch }
}
