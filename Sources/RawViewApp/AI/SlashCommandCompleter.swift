import SwiftUI

/// Definition of a slash command item for the AI chat composer autocomplete.
public struct SlashCommandItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let icon: String

    public init(id: String, name: String, description: String, icon: String) {
        self.id = id
        self.name = name
        self.description = description
        self.icon = icon
    }

    /// Default built-in skills for RawView
    public static let defaultItems: [SlashCommandItem] = [
        SlashCommandItem(
            id: "setup-grammar",
            name: "/setup-grammar",
            description: "Auto-infer tokens, variables & sidebar labels",
            icon: "text.textalignment.left"
        ),
        SlashCommandItem(
            id: "setup-profile",
            name: "/setup-profile",
            description: "Read raw file & generate Schema v3 profile",
            icon: "waveform.path.ecg"
        ),
        SlashCommandItem(
            id: "explain",
            name: "/explain",
            description: "Analyze focused curve & physical dimensions",
            icon: "chart.xyaxis.line"
        ),
        SlashCommandItem(
            id: "reindex",
            name: "/reindex",
            description: "Re-index project data sources & refresh views",
            icon: "arrow.clockwise"
        )
    ]
}

/// Floating autocomplete panel for slash commands.
public struct SlashCompletionMenu: View {
    public let items: [SlashCommandItem]
    public let selectedIndex: Int
    public let onSelect: (SlashCommandItem) -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AVAILABLE SKILLS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button(action: { onSelect(item) }) {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(index == selectedIndex ? Color.white : Color.accentColor)
                            .frame(width: 20, height: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(index == selectedIndex ? Color.white : Color.primary)
                            Text(item.description)
                                .font(.system(size: 10))
                                .foregroundStyle(index == selectedIndex ? Color.white.opacity(0.85) : Color.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == selectedIndex ? Color.accentColor : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.12), radius: 8, y: 2)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10), lineWidth: 1))
        )
        .frame(maxWidth: .infinity)
    }
}
