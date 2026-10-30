import AppKit
import ApplicationServices

/// Lager høyreklikk-menyen for et element.
///
/// Med Tilgjengelighet-tilgang åpnes den ekte Dock-menyen et øyeblikk, innholdet leses av og
/// vises som en identisk meny i kopien. Valg utføres ved å trykke på samme menypunkt i den ekte
/// Docken – dermed fungerer også app-spesifikke punkter («Nytt vindu», «Behold i Dock» osv.).
final class DockMenuProvider: NSObject {
    private struct Entry {
        var title: String
        var enabled: Bool
        var checked: Bool
        var children: [Entry]
        /// Vises bare når Option holdes inne (f.eks. «Tving avslutning»).
        var isAlternate: Bool
        var isSeparator: Bool { title.isEmpty && children.isEmpty }
    }

    private final class MirrorAction: NSObject {
        let element: AXUIElement
        let path: [(title: String, index: Int)]
        init(element: AXUIElement, path: [(title: String, index: Int)]) {
            self.element = element
            self.path = path
        }
    }

    private let queue = DispatchQueue(label: "dockeverywhere.menu", qos: .userInteractive)

    func menu(for item: DockItem, completion: @escaping (NSMenu?) -> Void) {
        guard let element = item.axElement, AX.isTrusted else {
            completion(fallbackMenu(for: item))
            return
        }
        queue.async {
            let entries = Self.readRealMenu(element)
            DispatchQueue.main.async {
                if let entries, !entries.isEmpty {
                    completion(self.build(entries, element: element, path: []))
                } else {
                    completion(self.fallbackMenu(for: item))
                }
            }
        }
    }

    // MARK: - Speiling av den ekte menyen

    private static func waitForMenu(on element: AXUIElement, timeout: TimeInterval = 0.8) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let menu = AX.children(element).first(where: { AX.role($0) == kAXMenuRole }), !AX.children(menu).isEmpty {
                return menu
            }
            usleep(10_000)
        } while Date() < deadline
        return nil
    }

    private static func submenu(of item: AXUIElement, open: Bool) -> AXUIElement? {
        if let sub = AX.children(item).first(where: { AX.role($0) == kAXMenuRole }), !AX.children(sub).isEmpty {
            return sub
        }
        guard open else { return nil }
        AX.perform(item, kAXPressAction)
        let deadline = Date().addingTimeInterval(0.4)
        repeat {
            usleep(15_000)
            if let sub = AX.children(item).first(where: { AX.role($0) == kAXMenuRole }), !AX.children(sub).isEmpty {
                return sub
            }
        } while Date() < deadline
        return nil
    }

    private static func close(_ menu: AXUIElement) {
        if !AX.perform(menu, kAXCancelAction) { escape() }
    }

    private static func readRealMenu(_ element: AXUIElement) -> [Entry]? {
        guard AX.perform(element, kAXShowMenuAction) else { return nil }
        guard let menu = waitForMenu(on: element) else {
            escape()
            return nil
        }
        defer { close(menu) }
        return parse(menu, depth: 0)
    }

    /// Lukker en Dock-meny vi ikke fikk tak i via Escape.
    private static func escape() {
        guard let pid = ScreenLocator.dockPID else { return }
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.postToPid(pid)
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.postToPid(pid)
    }

    private static func parse(_ menu: AXUIElement, depth: Int) -> [Entry] {
        AX.children(menu).compactMap { element in
            guard AX.role(element) == kAXMenuItemRole else { return nil }
            let title = AX.title(element) ?? ""
            let enabled = AX.bool(element, kAXEnabledAttribute) ?? true
            let mark = AX.string(element, kAXMenuItemMarkCharAttribute) ?? ""
            var children: [Entry] = []
            let hasSubmenu = AX.children(element).contains { AX.role($0) == kAXMenuRole }
            if hasSubmenu, depth < 2, enabled, let sub = submenu(of: element, open: true) {
                children = parse(sub, depth: depth + 1)
            }
            var isAlternate = false
            if let primary = AX.value(element, "AXMenuItemPrimaryUIElement"), CFGetTypeID(primary) == AXUIElementGetTypeID() {
                isAlternate = !CFEqual(primary, element)
            }
            return Entry(title: title, enabled: enabled, checked: !mark.isEmpty, children: children, isAlternate: isAlternate)
        }
    }

    private func build(_ entries: [Entry], element: AXUIElement, path: [(title: String, index: Int)]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, entry) in entries.enumerated() {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let itemPath = path + [(entry.title, index)]
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.enabled
            item.state = entry.checked ? .on : .off
            if entry.isAlternate, menu.items.last?.isSeparatorItem == false {
                item.isAlternate = true
                item.keyEquivalentModifierMask = .option
            }
            if entry.children.isEmpty {
                item.action = #selector(choose(_:))
                item.target = self
                item.representedObject = MirrorAction(element: element, path: itemPath)
            } else {
                item.submenu = build(entry.children, element: element, path: itemPath)
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MirrorAction else { return }
        queue.async { Self.perform(action) }
    }

    private static func perform(_ action: MirrorAction) {
        guard AX.perform(action.element, kAXShowMenuAction) else { return }
        guard let top = waitForMenu(on: action.element) else {
            escape()
            return
        }
        var menu = top
        for (depth, step) in action.path.enumerated() {
            let items = AX.children(menu).filter { AX.role($0) == kAXMenuItemRole }
            // Samme plass og samme tittel først (skiller like titler), ellers første med samme tittel.
            // Aldri et punkt med en annen tittel: menyen kan ha endret seg siden den ble lest.
            let sameSpot = step.index < items.count && (AX.title(items[step.index]) ?? "") == step.title
            guard let target = sameSpot ? items[step.index] : items.first(where: { (AX.title($0) ?? "") == step.title }) else {
                close(top)
                return
            }
            if depth == action.path.count - 1 {
                if !AX.perform(target, kAXPressAction) { close(top) }
                return
            }
            guard let sub = submenu(of: target, open: true) else {
                close(top)
                return
            }
            menu = sub
        }
    }

    // MARK: - Reservemeny (uten Tilgjengelighet)

    private func fallbackMenu(for item: DockItem) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch item.kind {
        case .application:
            let running = NSWorkspace.shared.runningApplications.first {
                ($0.bundleIdentifier != nil && $0.bundleIdentifier == item.bundleIdentifier) || $0.bundleURL == item.url
            }
            if let url = item.url {
                if running == nil {
                    menu.addItem(ClosureMenuItem("Åpne") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    })
                }
                menu.addItem(ClosureMenuItem("Vis i Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            }
            if let running {
                menu.addItem(.separator())
                if running.isHidden {
                    menu.addItem(ClosureMenuItem("Vis") { running.unhide() })
                } else {
                    menu.addItem(ClosureMenuItem("Skjul") { running.hide() })
                }
                menu.addItem(ClosureMenuItem("Avslutt") { running.terminate() })
            }
        case .folder, .file:
            guard let url = item.url else { return nil }
            menu.addItem(ClosureMenuItem("Åpne") { NSWorkspace.shared.open(url) })
            menu.addItem(ClosureMenuItem("Vis i Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        case .url:
            guard let url = item.url else { return nil }
            menu.addItem(ClosureMenuItem("Åpne") { NSWorkspace.shared.open(url) })
        case .trash:
            menu.addItem(ClosureMenuItem("Åpne") {
                if let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
                    NSWorkspace.shared.open(trash)
                }
            })
        case .minimizedWindow, .separator, .spacer:
            return nil
        }
        return menu.items.isEmpty ? nil : menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run() { handler() }
}
