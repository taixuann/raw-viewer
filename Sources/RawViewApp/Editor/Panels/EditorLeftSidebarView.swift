import SwiftUI
import RawViewCore

/// Panel 1 (Left Sidebar): Clean Profile Manager & Active Source
/// Focuses purely on:
/// - Active Target File card (sample filename, line count, switch sample menu, pin as example)
/// - Profile Identity (Profile ID, Display Name)
/// - Saved Profiles Library (scans .rawviewer/instrument/*.yaml, 1-click loading, import YAML profile)
/// - Sticky Actions Footer (Test Against Cohort, Build Profile Cmd+S)
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
                Label("Profile Manager", systemImage: "slider.horizontal.2.square")
                    .font(.system(size: 12, weight: .bold))
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
                    // 1. Active Target Sample Card
                    activeSourceCard

                    // 2. Profile Identity Card
                    profileIdentityCard

                    // 3. Saved Profiles Library & Import
                    savedProfilesCard
                }
                .padding(12)
            }

            Divider()

            // Sticky Bottom Actions
            sidebarActionFooter
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 1. Active Source Card
    private var activeSourceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Target Sample", systemImage: "doc.text")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let sel = model.selectedSource {
                        Text("\(sel.url.pathExtension.uppercased()) • \(model.editor.lines.count) lines")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // Active Source Display
                if let current = model.selectedSource {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(current.url.lastPathComponent)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                            Text(current.relativePath)
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(6)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(5)
                }

                // Action Bar: Switch Sample & Pin Example
                HStack(spacing: 6) {
                    Menu {
                        ForEach(sources.prefix(40)) { src in
                            Button(src.url.lastPathComponent) {
                                model.selectSource(src)
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

                    Button {
                        model.pinCurrentAsExample()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "pin.fill")
                            Text("Pin")
                        }
                        .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Pin current file as the canonical reference example in .rawviewer/instrument/examples/")
                }
            }
            .padding(4)
        }
    }

    // MARK: - 2. Profile Identity Card
    private var profileIdentityCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Profile Identity", systemImage: "cpu")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Profile ID")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !model.tokens.isEmpty {
                            Menu {
                                ForEach(model.tokens, id: \.self) { tok in
                                    Button(tok) {
                                        model.editor.instrumentID = tok
                                        if model.editor.instrumentName.isEmpty {
                                            model.editor.instrumentName = tok
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "wand.and.stars")
                                    Text("From Token…")
                                }
                                .font(.system(size: 9))
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                    TextField("e.g. autolab-pgstat", text: $model.editor.instrumentID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Display Name")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("e.g. Autolab PGSTAT302N", text: $model.editor.instrumentName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }
            .padding(4)
        }
    }

    // MARK: - 3. Saved Profiles Library & Import
    private var savedProfilesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Saved Profiles", systemImage: "folder")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.savedProfiles.count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if model.savedProfiles.isEmpty {
                    VStack(spacing: 4) {
                        Text("No saved profiles found")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 4) {
                        ForEach(model.savedProfiles, id: \.self) { profileURL in
                            Button {
                                model.loadSavedProfile(url: profileURL)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.badge.gearshape")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.accentColor)
                                    Text(profileURL.deletingPathExtension().lastPathComponent)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()

                Button {
                    model.importProfile()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import YAML Profile…")
                    }
                    .font(.system(size: 10))
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
            .padding(4)
        }
    }

    // MARK: - Sticky Footer
    private var sidebarActionFooter: some View {
        VStack(spacing: 8) {
            Button {
                model.testAgainstCohort()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal")
                    Text("Test Against Cohort")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)

            if let status = model.cohortTestResult {
                Text(status)
                    .font(.system(size: 9.5))
                    .foregroundStyle(model.cohortTestSuccess ? .green : .orange)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
            }

            Button {
                model.saveProfileAndRules()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 11))
                    Text("Build Profile")
                        .font(.system(size: 11, weight: .semibold))
                    ShortcutBadge("buildProfile")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.editor.instrumentID.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut("s", modifiers: [.command])
            .help("Builds and saves this instrument profile & category rules to .rawviewer/ (Cmd+S)")
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
