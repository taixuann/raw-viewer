import SwiftUI

public struct AppHotkey: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public var category: String
    public var key: String
    public var modifiers: [String] // "command", "shift", "option", "control"
    public var description: String

    public var displayString: String {
        var str = ""
        if modifiers.contains("control") { str += "⌃" }
        if modifiers.contains("option") { str += "⌥" }
        if modifiers.contains("shift") { str += "⇧" }
        if modifiers.contains("command") { str += "⌘" }
        str += key.uppercased()
        return str
    }
}

@MainActor
public final class HotkeyManager: ObservableObject {
    public static let shared = HotkeyManager()

    @Published public var hotkeys: [AppHotkey] = []

    private let storageKey = "userConfiguredHotkeys"

    public static let defaultHotkeys: [AppHotkey] = [
        AppHotkey(id: "openProject", name: "Open Project", category: "Navigation", key: "o", modifiers: ["command"], description: "Choose and open a research project folder"),
        AppHotkey(id: "buildProfile", name: "Save Focused Document", category: "Profile Studio", key: "s", modifiers: ["command"], description: "Save the focused editor document (profile or grammar)"),
        AppHotkey(id: "matrixMode", name: "Data Matrix View", category: "View", key: "1", modifiers: ["command"], description: "Switch center canvas to spreadsheet Data Matrix"),
        AppHotkey(id: "streamMode", name: "Raw Stream & Parser", category: "View", key: "2", modifiers: ["command"], description: "Switch center canvas to color-coded Raw Stream"),
        AppHotkey(id: "autoDetect", name: "Run Auto Detect", category: "Profile Studio", key: "d", modifiers: ["command"], description: "Run smart heuristics on active target file"),
        AppHotkey(id: "toggleInspector", name: "Toggle Inspector", category: "View", key: "i", modifiers: ["command"], description: "Toggle right-hand details & channels inspector"),
        AppHotkey(id: "exportFigure", name: "Export Figure", category: "Export", key: "e", modifiers: ["command"], description: "Export publication-ready vector or bitmap figure"),
        AppHotkey(id: "exportData", name: "Export CSV Data", category: "Export", key: "e", modifiers: ["command", "shift"], description: "Export current measurement channel series to CSV"),
    ]

    public init() {
        loadHotkeys()
    }

    public func shortcut(for id: String) -> String {
        hotkeys.first(where: { $0.id == id })?.displayString ?? ""
    }

    public func updateKey(for id: String, newKey: String, newModifiers: [String]) {
        if let idx = hotkeys.firstIndex(where: { $0.id == id }) {
            hotkeys[idx].key = newKey
            hotkeys[idx].modifiers = newModifiers
            saveHotkeys()
        }
    }

    public func resetToDefaults() {
        hotkeys = Self.defaultHotkeys
        saveHotkeys()
    }

    private func loadHotkeys() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AppHotkey].self, from: data) {
            self.hotkeys = decoded
            // Task 6: the single ⌘S command replaced per-button bindings;
            // migrate the stored label so the Hotkeys tab matches.
            if let idx = hotkeys.firstIndex(where: { $0.id == "buildProfile" }),
               hotkeys[idx].name == "Build Profile" {
                hotkeys[idx].name = "Save Focused Document"
                hotkeys[idx].description = "Save the focused editor document (profile or grammar)"
            }
        } else {
            self.hotkeys = Self.defaultHotkeys
        }
    }

    private func saveHotkeys() {
        if let data = try? JSONEncoder().encode(hotkeys) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}

/// Dynamic shortcut pill badge that automatically observes and reflects HotkeyManager changes
public struct ShortcutBadge: View {
    @ObservedObject private var manager = HotkeyManager.shared
    let id: String

    public init(_ id: String) {
        self.id = id
    }

    public var body: some View {
        let str = manager.shortcut(for: id)
        if !str.isEmpty {
            Text(str)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(Color.primary.opacity(0.12), lineWidth: 0.7))
        }
    }
}
