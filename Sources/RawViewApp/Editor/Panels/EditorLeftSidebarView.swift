import SwiftUI
import RawViewCore

/// Panel 1 (Left Sidebar): Active Target File card, Saved Profiles Library, and Import YAML action.
struct EditorLeftSidebarView: View {
    @ObservedObject var model: EditorWorkspaceViewModel
    let sources: [RawSource]

    init(model: EditorWorkspaceViewModel, sources: [RawSource]) {
        self.model = model
        self.sources = sources
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Sidebar Header
            HStack {
                Text("Profile Specification")
                    .font(.headline)
                Spacer()
                Button {
                    model.refreshSavedProfiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Refresh saved profiles")
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Active Target File Card
                    compactSourceCard

                    // Saved Profiles Library
                    savedProfilesLibrarySection
                }
                .padding(12)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Active Target File Card
    private var compactSourceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Active Target File", systemImage: "doc.text")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if model.selectedSource != nil {
                        Text("\(model.editor.lines.count) lines")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(.quaternary))
                    }
                }

                if let src = model.selectedSource {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(src.url.lastPathComponent)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text(src.relativePath)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))
                } else {
                    Text("No file selected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Sample Actions Bar: Switch File & Pin Example
                HStack(spacing: 6) {
                    // Switch Sample File Dropdown Menu
                    Menu {
                        ForEach(sources) { s in
                            Button(s.url.lastPathComponent) {
                                model.selectSource(s)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Switch Sample…")
                        }
                        .font(.system(size: 10))
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)

                    Spacer(minLength: 0)

                    // Pin Example Button
                    Button {
                        model.pinCurrentAsExample()
                    } label: {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.selectedSource == nil)
                    .help("Saves a copy of this sample file to .rawviewer/instrument/examples/ as canonical reference")
                }
            }
            .padding(4)
        }
    }

    // MARK: - Saved Profiles Library Section
    private var savedProfilesLibrarySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Saved Profiles Library", systemImage: "folder")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.savedProfiles.count) profiles")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                // 1-Click Load Profiles List
                if model.savedProfiles.isEmpty {
                    VStack(spacing: 4) {
                        Text("No saved profiles found.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Profiles saved to .rawviewer/instrument/ appear here.")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary.opacity(0.25)))
                } else {
                    VStack(spacing: 4) {
                        ForEach(model.savedProfiles, id: \.self) { profileURL in
                            Button {
                                model.loadSavedProfile(url: profileURL)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.badge.gearshape")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(profileURL.lastPathComponent)
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .lineLimit(1)
                                        Text(profileURL.deletingLastPathComponent().lastPathComponent)
                                            .font(.system(size: 8.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(model.editor.instrumentID == profileURL.deletingPathExtension().lastPathComponent
                                              ? Color.accentColor.opacity(0.12)
                                              : Color(NSColor.controlBackgroundColor))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Click to load \(profileURL.lastPathComponent)")
                        }
                    }
                }

                Divider().padding(.vertical, 2)

                // Import YAML Action
                Button {
                    model.importProfile()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import YAML Profile…")
                    }
                    .font(.system(size: 10.5))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
            .padding(4)
        }
    }
}
