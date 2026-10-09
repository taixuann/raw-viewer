import AppKit
import SwiftUI
import RawViewCore

struct SettingsView: View {
    @AppStorage("appTheme") private var appTheme: String = "System"
    @AppStorage("uiFontSize") private var uiFontSize: Double = 12.0
    @AppStorage("plotFontSerif") private var plotFontSerif: Bool = false
    @AppStorage("defaultLineWidth") private var defaultLineWidth: Double = 1.4
    @AppStorage("isLazyInspectionEnabled") private var isLazyInspectionEnabled: Bool = true
    @AppStorage("maxComparisonAutoLoad") private var maxComparisonAutoLoad: Int = 15
    @AppStorage("cacheLimitMB") private var cacheLimitMB: Int = 2048
    @State private var cacheClearedMessage: String?

    var body: some View {
        TabView {
            appearanceTab
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }
                .tag("appearance")

            performanceTab
                .tabItem {
                    Label("Performance", systemImage: "bolt.fill")
                }
                .tag("performance")

            storageTab
                .tabItem {
                    Label("Storage", systemImage: "internaldrive")
                }
                .tag("storage")
        }
        .frame(width: 480, height: 320)
        .padding(20)
    }

    private var appearanceTab: some View {
        Form {
            Section("Interface Theme & Sizing") {
                Picker("Theme:", selection: $appTheme) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: appTheme) { _, newTheme in
                    applyTheme(newTheme)
                }

                HStack {
                    Text("Font Size Preset:")
                    Slider(value: $uiFontSize, in: 10...16, step: 1)
                    Text("\(Int(uiFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 45, alignment: .trailing)
                }
            }

            Section("Plot Defaults") {
                Toggle("Use Nature Serif font for plot typography", isOn: $plotFontSerif)

                HStack {
                    Text("Default Line Width:")
                    TextField("1.4", value: $defaultLineWidth, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Stepper("", value: $defaultLineWidth, in: 0.2...10.0, step: 0.1)
                        .labelsHidden()
                        .controlSize(.small)
                    Text("pt").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var performanceTab: some View {
        Form {
            Section("File Discovery & Inspection") {
                Picker("Loading Mode:", selection: $isLazyInspectionEnabled) {
                    Text("Lazy (Inspect on demand - Instant startup)").tag(true)
                    Text("Eager (Inspect all files in background)").tag(false)
                }
                .pickerStyle(.radioGroup)

                Text("Lazy mode instantly opens large folders with thousands of files without background disk thrashing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Multi-Source Comparison") {
                Picker("Max Auto-Loaded Series:", selection: $maxComparisonAutoLoad) {
                    Text("5 series").tag(5)
                    Text("10 series").tag(10)
                    Text("15 series (Default)").tag(15)
                    Text("25 series").tag(25)
                    Text("50 series").tag(50)
                }

                Text("Caps concurrent loading to prevent memory spikes and freezes when selecting large cohorts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var storageTab: some View {
        Form {
            Section("Database Index") {
                LabeledContent("Index Format:", value: "SQLite WAL")
                LabeledContent("Path:", value: "data/.rawview/index.db")
                Text("Index files store parsed headers, sampling stats, and SHA256 fingerprints per research project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Disk Cache Limits") {
                HStack {
                    Text("Max RAM/Disk Cache:")
                    Picker("", selection: $cacheLimitMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("2 GB (Default)").tag(2048)
                        Text("4 GB").tag(4096)
                        Text("8 GB").tag(8192)
                    }
                    .onChange(of: cacheLimitMB) { _, newMB in
                        UserDefaults.standard.set(Int64(newMB) * 1024 * 1024, forKey: "cacheLimitBytes")
                    }
                }

                if let message = cacheClearedMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func applyTheme(_ theme: String) {
        switch theme {
        case "Light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "Dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
}
