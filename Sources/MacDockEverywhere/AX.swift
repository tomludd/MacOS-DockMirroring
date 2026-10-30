import AppKit
import ApplicationServices

/// Små hjelpere rundt Accessibility-API-et (AXUIElement).
enum AX {
    static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (value(element, attribute) as? NSNumber)?.boolValue
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (value(element, attribute) as? [AXUIElement]) ?? []
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        elements(element, kAXChildrenAttribute)
    }

    static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }
    static func subrole(_ element: AXUIElement) -> String? { string(element, kAXSubroleAttribute) }
    static func title(_ element: AXUIElement) -> String? { string(element, kAXTitleAttribute) }

    static func url(from value: CFTypeRef?) -> URL? {
        guard let value else { return nil }
        if CFGetTypeID(value) == CFURLGetTypeID() { return (value as! CFURL) as URL }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    /// Fjerner AXValue-feilmarkører fra resultatet av AXUIElementCopyMultipleAttributeValues.
    static func cleaned(_ value: AnyObject) -> AnyObject? {
        if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
        if value is NSNull { return nil }
        return value
    }

    @discardableResult
    static func perform(_ element: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        return (names as? [String]) ?? []
    }

    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        return (names as? [String]) ?? []
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }
}
