import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DockController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Debug.handleArguments()
        setupStatusItem()
        if !AX.isTrusted {
            AX.requestTrust(prompt: true)
            // Når tilgangen gis, går vi over til å lese den ekte Docken direkte (uten å spørre jevnlig).
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(accessibilityChanged),
                                                                name: NSNotification.Name("com.apple.accessibility.api"),
                                                                object: nil)
        }
        controller.start()
        Debug.runMenuTestIfRequested(controller: controller)
    }

    @objc private func accessibilityChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if AX.isTrusted { self?.controller.refreshItems() }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Dock Everywhere")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Dock Everywhere", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !controller.isActive {
            let idle = NSMenuItem(title: "Hviler – kobler til igjen når en ekstra skjerm kobles til", action: nil, keyEquivalent: "")
            idle.isEnabled = false
            menu.addItem(idle)
        }

        if AX.isTrusted {
            let ok = NSMenuItem(title: "Tilgjengelighet: aktivert", action: nil, keyEquivalent: "")
            ok.isEnabled = false
            menu.addItem(ok)
        } else {
            menu.addItem(ClosureMenuItem("Gi tilgang til Tilgjengelighet …") {
                AX.requestTrust(prompt: true)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            })
        }

        let glass = NSMenuItem(title: "Glass", action: nil, keyEquivalent: "")
        let glassMenu = NSMenu()
        for mode in GlassMode.allCases {
            let item = ClosureMenuItem(mode.title) { [weak self] in
                GlassMode.current = mode
                self?.controller.updateGlass()
            }
            item.state = GlassMode.current == mode ? .on : .off
            glassMenu.addItem(item)
        }
        glass.submenu = glassMenu
        menu.addItem(glass)

        // Valgfritt: gir glass som tilpasser seg bakgrunnen og ekte miniatyrbilder av minimerte vinduer.
        let capture = ClosureMenuItem("Bruk skjermopptak (glass og miniatyrbilder)") { [weak self] in
            ScreenCapture.isEnabled.toggle()
            if ScreenCapture.isEnabled, !ScreenCapture.hasPermission {
                CGRequestScreenCaptureAccess()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            self?.controller.screenCaptureSettingChanged()
        }
        capture.state = ScreenCapture.isEnabled ? (ScreenCapture.hasPermission ? .on : .mixed) : .off
        menu.addItem(capture)

        menu.addItem(.separator())
        let login = ClosureMenuItem("Start ved innlogging") {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Avslutt Dock Everywhere", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
