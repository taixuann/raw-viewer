import AppKit
import SwiftUI
import RawViewCore

struct ExplorerToolbarCommands: Commands {
    @ObservedObject var model: RawViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Project…") {
                model.openProject()
            }
            .keyboardShortcut("o", modifiers: [.command])

            Menu("Open Recent") {
                if model.recentProjects.isEmpty {
                    Text("No Recent Projects").foregroundStyle(.secondary)
                } else {
                    ForEach(model.recentProjects, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            model.openRecentProject(url: url)
                        }
                    }
                    Divider()
                    Button("Clear Menu") {
                        model.clearRecentProjects()
                    }
                }
            }
        }

        CommandMenu("View") {
            Button("Switch to Explorer") {
                model.activeWorkspaceMode = .explorer
            }
            .keyboardShortcut("1", modifiers: [.command])

            Button("Switch to Profile Editor") {
                model.activeWorkspaceMode = .editor
            }
            .keyboardShortcut("2", modifiers: [.command])

            Divider()

            Button("Toggle Inspector") {
                model.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command])
        }

        CommandMenu("Project") {
            Button("Reload Index") {
                _ = model.resumeInspection()
            }
            .keyboardShortcut("r", modifiers: [.command])

            Button("Reindex All Sources") {
                model.reindexAllSources()
            }
        }
    }
}
