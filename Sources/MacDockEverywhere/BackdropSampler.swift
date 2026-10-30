import AppKit
import ScreenCaptureKit

/// Den ekte Docken gjør glasset mørkt over mørk bakgrunn og lyst over lys bakgrunn.
/// Med Skjermopptak slått på måler vi lysstyrken bak Docken; ellers følger glasset systemets utseende.
enum GlassMode: String, CaseIterable {
    case automatic, light, dark

    private static let key = "glassMode"

    static var current: GlassMode {
        get { GlassMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .automatic: return "Automatisk (følger bakgrunnen med skjermopptak, ellers systemet)"
        case .light: return "Lyst"
        case .dark: return "Mørkt"
        }
    }
}

/// Skjermopptak er valgfritt: det brukes bare til å tilpasse glasset og vise ekte miniatyrbilder
/// av minimerte vinduer, og bare når brukeren har slått det på i menyen.
enum ScreenCapture {
    private static let key = "useScreenCapture"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Slått på og tillatt.
    static var isAvailable: Bool { isEnabled && hasPermission }
}

/// Brukes bare fra hovedtråden; opptaket kjøres som en oppgave på hovedaktøren.
final class BackdropSampler: @unchecked Sendable {
    private var lastResult: [CGDirectDisplayID: Bool] = [:]

    /// `rect` er i punkter relativt til skjermen, med origo øverst til venstre.
    /// Svarer `nil` hvis vi ikke kan måle (mangler tilgang e.l.).
    func isDark(displayID: CGDirectDisplayID, rect: CGRect, completion: @escaping (Bool?) -> Void) {
        guard ScreenCapture.isAvailable, rect.width > 1, rect.height > 1 else {
            completion(nil)
            return
        }
        let previous = lastResult[displayID]
        Task { @MainActor in
            var result: Bool?
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if let display = content.displays.first(where: { $0.displayID == displayID }) {
                    let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.sourceRect = rect
                    config.width = 96
                    config.height = 8
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    if let luminance = Self.averageLuminance(image) {
                        // Litt hysterese så glasset ikke blafrer ved grensen.
                        let threshold = previous == true ? 0.55 : (previous == false ? 0.45 : 0.5)
                        result = luminance < threshold
                    }
                }
            } catch {
                Log.write("måling av bakgrunn feilet: \(error) rect=\(rect.debugDescription)")
                result = nil
            }
            if let result { self.lastResult[displayID] = result }
            completion(ScreenCapture.isAvailable ? result : nil)
        }
    }

    private static func averageLuminance(_ image: CGImage) -> Double? {
        let w = 32, h = 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return total / Double(w * h) / 255
    }
}
