import Foundation
import IOKit.ps

/// Om maskinen går på batteri, så vi kan spørre sjeldnere.
enum PowerSource {
    static let didChange = Notification.Name("DockEverywherePowerSourceDidChange")

    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }

    private static var source: CFRunLoopSource?

    static func startObserving() {
        guard source == nil,
              let created = IOPSNotificationCreateRunLoopSource({ _ in
                  NotificationCenter.default.post(name: PowerSource.didChange, object: nil)
              }, nil)?.takeRetainedValue() else { return }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
    }
}
