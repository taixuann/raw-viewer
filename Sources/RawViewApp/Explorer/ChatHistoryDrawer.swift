import SwiftUI
import RawViewCore

/// A saved session summary for the history list.
struct SavedSessionSummary: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let dateString: String
    let preview: String
}

/// History drawer listing past saved sessions from `.rawviewer/session/YYYY-MM-DD/`.
/// Direct 1:1 port of OakReader's ChatHistoryDrawer.
struct ChatHistoryDrawer: View {
    @ObservedObject var model: RawViewModel
    var onSelect: (UUID) -> Void

    @State private var sessions: [SavedSessionSummary] = []
    @State private var hoveredId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if sessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .task {
            loadSessions()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No conversations yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Start a new chat to see it here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(sessions) { session in
                    let isSelected = session.id == model.aiChatSessionId
                    let isHovered = hoveredId == session.id

                    Button {
                        onSelect(session.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(session.preview)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                                    .lineLimit(1)
                                Spacer()
                                Text(session.dateString)
                                    .font(.system(size: 10))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredId = hovering ? session.id : nil
                    }
                }
            }
            .padding(10)
        }
    }

    private func loadSessions() {
        guard let project = model.project else { return }
        let sessionBase = project.root.appendingPathComponent(".rawviewer/session", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessionBase.path) else {
            self.sessions = []
            return
        }

        var results: [SavedSessionSummary] = []
        let dayDirs = (try? FileManager.default.contentsOfDirectory(at: sessionBase, includingPropertiesForKeys: nil)) ?? []
        for dir in dayDirs where dir.hasDirectoryPath {
            let dayName = dir.lastPathComponent
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let uuidString = file.deletingPathExtension().lastPathComponent
                guard let uuid = UUID(uuidString: uuidString) else { continue }
                let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

                // Read first line to get snippet
                var snippet = "New Chat"
                if let content = try? String(contentsOf: file, encoding: .utf8),
                   let firstLine = content.split(separator: "\n").first,
                   let data = firstLine.data(using: .utf8),
                   let turn = try? JSONDecoder().decode(ChatTurn.self, from: data) {
                    snippet = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if snippet.count > 50 {
                        snippet = String(snippet.prefix(50)) + "…"
                    }
                }

                results.append(SavedSessionSummary(
                    id: uuid,
                    date: modDate,
                    dateString: dayName,
                    preview: snippet.isEmpty ? "New Chat" : snippet
                ))
            }
        }

        // Sort descending by date
        results.sort { $0.date > $1.date }
        self.sessions = results
    }
}
