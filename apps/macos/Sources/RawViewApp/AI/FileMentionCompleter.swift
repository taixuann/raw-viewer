import SwiftUI
import RawViewCore

/// Model item for @ file mentions in AI chat composer.
public struct FileMentionItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let typeName: String

    public init(id: String, name: String, path: String, typeName: String = "data") {
        self.id = id
        self.name = name
        self.path = path
        self.typeName = typeName
    }
}

/// Floating autocomplete popover when user types @ in the chat composer.
public struct FileMentionCompletionMenu: View {
    public let items: [FileMentionItem]
    public let selectedIndex: Int
    public let onSelect: (FileMentionItem) -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MENTION A FILE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, item in
                Button(action: { onSelect(item) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12))
                            .foregroundStyle(index == selectedIndex ? Color.white : Color.accentColor)
                            .frame(width: 20, height: 20)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("@" + item.name)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(index == selectedIndex ? Color.white : Color.primary)
                                .lineLimit(1)
                            Text(item.path)
                                .font(.system(size: 9))
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
