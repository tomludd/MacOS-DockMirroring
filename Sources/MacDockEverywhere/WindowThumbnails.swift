import AppKit
import ScreenCaptureKit

/// Henter bilder av minimerte vinduer via ScreenCaptureKit, slik at kopien viser
/// de samme miniatyrbildene som den ekte Docken (bare når Skjermopptak er slått på).
/// Brukes bare fra hovedtråden; opptaket kjøres som en oppgave på hovedaktøren.
final class WindowThumbnails: @unchecked Sendable {
    static let shared = WindowThumbnails()

    var onUpdate: (() -> Void)?
    private var images: [String: NSImage] = [:]
    private var capturing = false
    private var retryAfter = Date.distantPast
    /// Økes ved `clear()`, så et opptak som allerede pågår ikke fyller på igjen etterpå.
    private var generation = 0

    func thumbnail(for item: DockItem) -> NSImage? { images[key(item)] }

    private func key(_ item: DockItem) -> String { "\(item.id)@\(item.ownerPID ?? 0)" }

    func clear() {
        generation += 1
        images.removeAll()
        onUpdate?()
    }

    func refresh(_ items: [DockItem]) {
        let minimized = items.filter { $0.kind == .minimizedWindow }
        let keys = Set(minimized.map(key))
        images = images.filter { keys.contains($0.key) }
        let missing = minimized.filter { images[key($0)] == nil }
        guard !missing.isEmpty, !capturing, Date() > retryAfter, ScreenCapture.isAvailable else { return }
        capturing = true
        let started = generation

        Task { @MainActor in
            var captured: [(key: String, image: CGImage, icon: URL?)] = []
            if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) {
                var used = Set<CGWindowID>()
                for item in missing {
                    // Uten kjent eier (f.eks. vindu på et annet skrivebord) søker vi i alle apper.
                    let candidates = content.windows.filter {
                        (item.ownerPID == nil || $0.owningApplication?.processID == item.ownerPID) && !$0.isOnScreen
                            && $0.windowLayer == 0 && $0.frame.width > 50 && $0.frame.height > 50 && !used.contains($0.windowID)
                    }
                    guard let window = candidates.first(where: { $0.title == item.title })
                        ?? candidates.first(where: { DockReader.titleMatches($0.title ?? "", item.title) })
                        ?? (item.ownerPID != nil && candidates.count == 1 ? candidates.first : nil) else { continue }
                    used.insert(window.windowID)
                    let iconURL = item.url ?? window.owningApplication.flatMap {
                        NSRunningApplication(processIdentifier: $0.processID)?.bundleURL
                    }
                    let scale = min(1, 512 / max(window.frame.width, window.frame.height))
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int(window.frame.width * scale))
                    config.height = max(1, Int(window.frame.height * scale))
                    config.showsCursor = false
                    if let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) {
                        captured.append((key(item), image, iconURL))
                    }
                }
            }
            self.capturing = false
            guard started == self.generation, ScreenCapture.isAvailable else { return }
            if captured.count < missing.count { self.retryAfter = Date().addingTimeInterval(30) }
            for entry in captured {
                self.images[entry.key] = Self.compose(entry.image, appIcon: IconProvider.shared.fileIcon(entry.icon))
            }
            if !captured.isEmpty { self.onUpdate?() }
        }
    }

    /// Vindusbilde med appikonet nede i høyre hjørne, som i Docken.
    private static func compose(_ window: CGImage, appIcon: NSImage?) -> NSImage {
        let snapshot = NSImage(cgImage: window, size: NSSize(width: window.width, height: window.height))
        return NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let s = rect.width
            let aspect = CGFloat(window.width) / CGFloat(max(window.height, 1))
            var w = s * 0.94
            var h = w / aspect
            if h > s * 0.94 {
                h = s * 0.94
                w = h * aspect
            }
            let frame = NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = s * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
            shadow.set()
            snapshot.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            let icon = s * 0.4
            appIcon?.draw(in: NSRect(x: frame.maxX - icon * 0.8, y: frame.minY - icon * 0.25, width: icon, height: icon))
            return true
        }
    }
}
