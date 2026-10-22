import AppKit

/// Menu bar icons (design/menubar.html). One colour: drawn as template images, which macOS
/// tints black or white to match the menu bar. Picked in Appearance; Comb is the default.
enum MenuBarIcon: String, CaseIterable, Identifiable {
    case tilted, comb, pill, classic
    var id: String { rawValue }
    var label: String {
        switch self { case .tilted: "Tilted mic"; case .comb: "Comb"; case .pill: "Pill"; case .classic: "Classic mic" }
    }

    static var current: MenuBarIcon {
        MenuBarIcon(rawValue: UserDefaults.standard.string(forKey: "menuIcon") ?? "") ?? .comb
    }

    func image(recording: Bool) -> NSImage {
        let svg = recording ? recordingSVG : idleSVG
        let full = #"<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">"# + svg + "</svg>"
        let image = NSImage(data: Data(full.utf8)) ?? NSImage(systemSymbolName: "mic", accessibilityDescription: nil)!
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = recording ? "Fluent, recording" : "Fluent"
        return image
    }

    private var stroke: String { #"fill="none" stroke="black" stroke-linecap="round" stroke-linejoin="round""# }

    private var idleSVG: String {
        switch self {
        case .tilted: #"<g \#(stroke) stroke-width="1.35"><rect x="7.1" y="1.6" width="5.4" height="9.4" rx="2.7" transform="rotate(32 9.8 6.3)"/><path d="M6.9 6.6l3.5 2.2M8.6 9.9V15.6M5.4 15.8h6.4"/></g>"#
        case .comb: #"<path \#(stroke) stroke-width="1.3" d="M3 8v2M5.5 6.5v5M8 5v8M10.5 6v6M13 7v4M15.5 8.2v1.6"/>"#
        case .pill: #"<g \#(stroke) stroke-width="1.25"><rect x="1.2" y="5.2" width="15.6" height="7.6" rx="3.8"/><path d="M5.5 8.4v1.2M7.5 7.6v2.8M9.5 7.1v3.8M11.5 7.6v2.8M13.5 8.4v1.2"/></g>"#
        case .classic: #"<g \#(stroke) stroke-width="1.35"><rect x="6.3" y="1.8" width="5.4" height="9" rx="2.7"/><path d="M3.8 8.6a5.2 5.2 0 0 0 10.4 0M9 13.8v2.4"/></g>"#
        }
    }

    private var recordingSVG: String {
        switch self {
        case .tilted: #"<g \#(stroke) stroke-width="1.35"><rect x="7.1" y="1.6" width="5.4" height="9.4" rx="2.7" transform="rotate(32 9.8 6.3)"/><path d="M8.6 9.9V15.6M5.4 15.8h6.4"/></g><circle cx="14.6" cy="13.2" r="2.1" fill="black"/>"#
        case .comb: #"<path \#(stroke) stroke-width="1.5" d="M3 6.5v5M5.5 3.5v11M8 5.5v7M10.5 2.5v13M13 4.5v9M15.5 7v4"/>"#
        case .pill: #"<path fill="black" fill-rule="evenodd" d="M5 5.2h8a3.8 3.8 0 0 1 0 7.6H5a3.8 3.8 0 0 1 0-7.6z M4.9 7.6h1.2v2.8H4.9z M6.9 6.9h1.2v4.2H6.9z M8.9 6.4h1.2v5.2H8.9z M10.9 7h1.2v4h-1.2z M12.9 7.9h1.2v2.2h-1.2z"/>"#
        case .classic: #"<rect x="6.3" y="1.8" width="5.4" height="9" rx="2.7" fill="black"/><path \#(stroke) stroke-width="1.35" d="M3.8 8.6a5.2 5.2 0 0 0 10.4 0M9 13.8v2.4"/>"#
        }
    }
}
