import SwiftUI
import RawViewCore

/// Panel 1 (Left Sidebar): Clean Profile Manager & Active Source
/// Focuses purely on:
/// - Active Target File card (sample filename, line count, switch sample menu, pin as example)
/// - Saved Profiles Library (scans .rawviewer/instrument/*.yaml, 1-click loading, import YAML profile)
/// - Sticky Actions Footer (Test Against Cohort, Build Profile Cmd+S)
struct EditorLeftSidebarView: View {
    @ObservedObject var model: EditorWorkspaceViewModel
    let sources: [RawSource]

    @State private var showingChooseSample = false
    @State private var chooseSampleFilter = ""

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
                    // 1. Saved Profiles Library & Import (Profiles first)
                    savedProfilesCard

                    // 2. Active Target Sample Card (preview input only)
                    activeSourceCard
                }
                .padding(12)
            }

            Divider()

            // Sticky Bottom Actions
            sidebarActionFooter
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 2. Active Source Card (preview input)
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

                Text("Preview input — switching never rewrites profile definitions.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)

                // Task 5: exact profile/variant confirmation state (never generic).
                matchStatusRow

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

                // Action Bar: searchable Choose sample over every source.
                // A manual pick switches immediately but stays unconfirmed
                // until the exact profile/variant check confirms it.
                HStack(spacing: 6) {
                    Button {
                        chooseSampleFilter = ""
                        showingChooseSample = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Choose Sample…")
                        }
                        .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Search every source; manual picks stay unconfirmed until checked.")
                    .popover(isPresented: $showingChooseSample) {
                        chooseSampleView
                    }

                    Spacer(minLength: 0)

                    switch model.previewMatch {
                    case .ioError, .ambiguous, .noMatch:
                        Button("Re-check") { model.retryPreviewMatch() }
                            .controlSize(.small)
                            .help("Re-run the preview match for the active profile and variant.")
                    default:
                        EmptyView()
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Task 5: match status + searchable Choose sample

    /// Confirmation state for the active profile AND variant. Searching,
    /// Match confirmed, No matching sample, Ambiguous, I/O error (with
    /// Retry), or Unconfirmed for manual picks awaiting the check.
    @ViewBuilder
    private var matchStatusRow: some View {
        switch model.previewMatch {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching for a matching sample…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Searching for a matching sample")
        case .confirmed(let id):
            Label("Match confirmed: \(Self.displayName(id))", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(.green)
        case .unconfirmed(let id):
            Label("Unconfirmed: \(Self.displayName(id)) — not yet checked against the active variant.",
                  systemImage: "questionmark.circle")
                .font(.system(size: 9.5))
                .foregroundStyle(.orange)
        case .noMatch:
            Text("No matching sample — preview is unconfirmed. Choose a sample to check it.")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        case .ambiguous(let note):
            VStack(alignment: .leading, spacing: 2) {
                Label("Ambiguous match — refine variant keys or selectors.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.orange)
                Text(note)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        case .ioError(let note):
            VStack(alignment: .leading, spacing: 2) {
                Label("Sample check I/O error.", systemImage: "xmark.circle")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.red)
                Text(note)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Retry") { model.retryPreviewMatch() }
                    .controlSize(.small)
            }
        }
    }

    private static func displayName(_ relativePath: String) -> String {
        URL(fileURLWithPath: relativePath).lastPathComponent
    }

    /// Searchable list over every source (no prefix cap). Picking switches
    /// the preview immediately; the match row marks it unconfirmed until
    /// the exact profile/variant check confirms it.
    private var chooseSampleView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose Sample")
                .font(.system(size: 12, weight: .bold))
            Text("Every source is listed. A manual pick stays unconfirmed until checked.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Filter sources", text: $chooseSampleFilter)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))
            if filteredSources.isEmpty {
                Text("No sources match the filter.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                List(filteredSources) { src in
                    Button {
                        model.chooseSamplePreview(src)
                        showingChooseSample = false
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(src.url.lastPathComponent)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Text(src.relativePath)
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 220)
            }
            HStack {
                Button("Cancel") { showingChooseSample = false }
                    .controlSize(.small)
                Spacer()
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var filteredSources: [RawSource] {
        let query = chooseSampleFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return model.sources }
        return model.sources.filter {
            ($0.url.lastPathComponent + " " + $0.relativePath).lowercased().contains(query)
        }
    }

    // MARK: - 1. Saved Profiles Library & Import
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
                                model.requestProfileSwitch(to: profileURL)
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
                    Text("Save Profile")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.editor.instrumentID.trimmingCharacters(in: .whitespaces).isEmpty && !model.hasProfileDocument)
            .help("Saves the whole profile document, rules and grammar with per-part status (⌘S saves the focused document instead)")
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
