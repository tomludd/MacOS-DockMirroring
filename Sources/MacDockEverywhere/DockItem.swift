import AppKit
import ApplicationServices

enum DockItemKind: Equatable {
    case application, folder, file, url, trash, separator, spacer, minimizedWindow
}

/// Ett element i Docken, slik det vises i den ekte Docken.
struct DockItem {
    var id: String
    var kind: DockItemKind
    var title: String
    var url: URL?
    var bundleIdentifier: String?
    var isRunning = false
    var badge: String?
    /// Fremdrift (0–1) som appen viser på ikonet, f.eks. nedlastinger.
    var progress: Double?
    /// Prosessen som eier et minimert vindu.
    var ownerPID: pid_t?
    /// Elementet i den ekte Docken (nil når vi mangler Tilgjengelighet-tilgang).
    var axElement: AXUIElement?

    var isSelectable: Bool { kind != .separator && kind != .spacer }

    /// Stabil nøkkel for en URL (filstier uten avsluttende skråstrek).
    static func key(for url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }
}

extension DockItem: Equatable {
    static func == (l: DockItem, r: DockItem) -> Bool {
        l.id == r.id && l.kind == r.kind && l.title == r.title && l.url == r.url
            && l.bundleIdentifier == r.bundleIdentifier && l.isRunning == r.isRunning
            && l.badge == r.badge && l.progress == r.progress && l.ownerPID == r.ownerPID
    }
}

/// Info om kjørende apper, hentet på hovedtråden og sendt til leseren.
struct RunningAppInfo {
    let pid: pid_t
    let url: URL?
    let bundleIdentifier: String?
    let name: String
}
