import CryptoKit
import Foundation

struct ProfileColumn: Sendable, Equatable {
    let key: String
    let header: String?
    let aliases: [String]
    let quantity: String
    let unit: String
    let label: String
    /// Positional source column for headerless layouts; nil for header-name layouts.
    let index: Int?
    /// Schema v2 tabular only: a `false` channel resolves when its header is
    /// present and is skipped when absent. Required channels always resolve.
    let required: Bool
}

struct ProfileFormat: Sendable, Equatable {
    let id: String
    let kind: String
    let extensions: [String]
    let delimiter: Character
    let encodings: [String.Encoding]
    let encodingNames: [String]
    let decimalSeparator: Character
    /// Row-block markers for `tabular` layouts; nil otherwise.
    let namesPrefix: String?
    let dataPrefix: String?
    let columns: [ProfileColumn]

    func column(named key: String) -> ProfileColumn? { columns.first { $0.key == key } }
}

struct ProfileMode: Sendable, Equatable {
    let id: String
    let formatID: String
    let detect: [String]
    let x: String
    let y: [String]
}

struct InstrumentProfile: Sendable, Equatable {
    let instrumentID: String
    let instrumentName: String
    let vendor: String?
    let model: String?
    let formats: [ProfileFormat]
    let modes: [ProfileMode]
    let relativePath: String
    let sha256: String
    let schemaVersion: Int
}

struct ProfileMatch: Sendable {
    let profile: InstrumentProfile
    let format: ProfileFormat
    let mode: ProfileMode
}

enum ProfileResolution: Sendable {
    case matched(ProfileMatch)
    case failed(String)
}

struct BrokenClaim: Sendable {
    /// A syntactically parseable but schema-invalid profile, kept whole: its
    /// selectors and diagnostics are never mixed with another profile's, so one
    /// broken profile cannot borrow another's signatures.
    let relativePath: String
    let extensions: [String]
    let signatures: [String]
    let issues: [String]

    func conflicts(sample: String) -> Bool {
        !sample.isEmpty && signatures.contains { sample.contains($0.lowercased()) }
    }
}

struct ProfileLoadOutcome: Sendable {
    let profile: InstrumentProfile?
    let issues: [String]
    let extensions: [String]
    /// Lenient detect-signature evidence from a syntactically parseable but
    /// schema-invalid profile. Malformed YAML supplies no selectors.
    let signatures: [String]
}

struct ProfileCatalog: Sendable {
    static let supportedSchemaVersions = [1, 2]
    static let maximumProfileBytes = 1 << 20

    let profiles: [InstrumentProfile]
    let issues: [String]
    let brokenClaims: [BrokenClaim]

    static func load(project: ProjectContext) -> ProfileCatalog {
        let instrumentsRoot = project.root.appendingPathComponent("data/instruments", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard instrumentsRoot.path.hasPrefix(project.root.path + "/") else {
            return ProfileCatalog(profiles: [], issues: ["data/instruments resolves outside this project. No profiles were loaded."], brokenClaims: [])
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: instrumentsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: instrumentsRoot.path) else {
            return ProfileCatalog(profiles: [], issues: [], brokenClaims: [])
        }

        // The companion directory is authoritative when the entry exists at
        // all: an empty, unreadable, or escaping one fails closed instead of
        // silently falling back to the Study-owned parent profiles.
        let companionEntry = instrumentsRoot.appendingPathComponent("rawview", isDirectory: true)
        var companionStat = stat()
        let lstatResult = lstat(companionEntry.path, &companionStat)
        if lstatResult == 0 {
            let companionRoot = companionEntry.resolvingSymlinksInPath().standardizedFileURL
            guard companionRoot.path.hasPrefix(instrumentsRoot.path + "/") else {
                return ProfileCatalog(profiles: [], issues: ["data/instruments/rawview resolves outside data/instruments. No profiles were loaded."], brokenClaims: [])
            }
            var companionIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: companionRoot.path, isDirectory: &companionIsDirectory), companionIsDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: companionRoot.path) else {
                return ProfileCatalog(profiles: [], issues: ["data/instruments/rawview is not a readable directory. No profiles were loaded."], brokenClaims: [])
            }
            return loadProfiles(from: companionRoot, displayRoot: "data/instruments/rawview", project: project)
        }
        // Only a proven-absent entry (ENOENT) falls back to the parent
        // directory. Any other lstat failure (for example a search-permission
        // error on data/instruments) gives no evidence either way, so the
        // catalog fails closed with a diagnostic instead of guessing.
        guard errno == ENOENT else {
            let reason = String(cString: strerror(errno))
            return ProfileCatalog(profiles: [], issues: [
                "data/instruments/rawview could not be examined (\(reason)); no profiles were loaded."
            ], brokenClaims: [])
        }
        return loadProfiles(from: instrumentsRoot, displayRoot: "data/instruments", project: project)
    }

    private static func loadProfiles(from root: URL, displayRoot: String, project: ProjectContext) -> ProfileCatalog {
        var profiles: [InstrumentProfile] = []
        var issues: [String] = []
        var brokenClaims: [BrokenClaim] = []
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )) ?? []

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fileExtension = entry.pathExtension.lowercased()
            guard fileExtension == "yaml" || fileExtension == "yml" else { continue }
            let canonical = entry.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(root.path + "/") else {
                issues.append("\(displayRoot)/\(entry.lastPathComponent): profile resolves outside \(displayRoot); skipped.")
                continue
            }
            let relativePath = String(canonical.path.dropFirst(project.root.path.count + 1))
            guard let values = try? canonical.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                issues.append("\(relativePath): profile is not a readable regular file; skipped.")
                continue
            }
            // The secured handle pins the exact object validated above; the
            // profile bytes are read and hashed from this same handle.
            let handle: FileHandle
            do {
                handle = try SecureFile.openVerified(resolvedPath: canonical.path, beneath: project.root.path)
            } catch let error as SecureOpenError {
                issues.append(error.profileIssue(display: relativePath))
                continue
            } catch {
                issues.append("\(relativePath): profile could not be opened: \(error.localizedDescription); skipped.")
                continue
            }
            let raw: Data
            do {
                raw = try handle.read(upToCount: maximumProfileBytes + 1) ?? Data()
            } catch {
                issues.append("\(relativePath): profile is not readable; skipped.")
                continue
            }
            guard raw.count <= maximumProfileBytes else {
                issues.append("\(relativePath): profile exceeds the 1 MiB profile limit; skipped.")
                continue
            }
            guard let text = String(data: raw, encoding: .utf8) else {
                issues.append("\(relativePath): profile is not readable UTF-8 text; skipped.")
                continue
            }
            let outcome = ProfileSchema.load(text: text, relativePath: relativePath, sha256: sha256Hex(raw))
            if let profile = outcome.profile {
                profiles.append(profile)
            } else {
                issues.append(contentsOf: outcome.issues)
                if !outcome.extensions.isEmpty {
                    brokenClaims.append(BrokenClaim(relativePath: relativePath, extensions: outcome.extensions, signatures: outcome.signatures, issues: outcome.issues))
                }
            }
        }
        return ProfileCatalog(profiles: profiles, issues: issues, brokenClaims: brokenClaims)
    }

    func hasBrokenClaim(for fileExtension: String) -> Bool {
        brokenClaims.contains { $0.extensions.contains(fileExtension) }
    }

    func hasValidClaim(for fileExtension: String) -> Bool {
        profiles.contains { $0.formats.contains { $0.extensions.contains(fileExtension) } }
    }

    /// Resolves one source by extension and bounded header sample. Every failure
    /// message names the profile(s) and field or signature that would fix it.
    /// Per-source isolation: a uniquely matched valid source stays usable beside
    /// an invalid profile claiming the same extension only when the invalid
    /// profile's own declared signatures provably do not match this source. A
    /// conflicting same-source signature, or an undecidable claim with no
    /// trustworthy selectors, keeps the source blocked instead of claiming a
    /// unique mapping.
    func resolve(extension fileExtension: String, headerSample: String) -> ProfileResolution {
        let valid = profiles.filter { profile in
            profile.formats.contains { $0.extensions.contains(fileExtension) }
        }
        let claims = brokenClaims.filter { $0.extensions.contains(fileExtension) }

        let sample = headerSample.lowercased()
        var matches: [ProfileMatch] = []
        var misses: [String] = []
        for profile in valid {
            for format in profile.formats where format.extensions.contains(fileExtension) {
                let modes = profile.modes.filter { $0.formatID == format.id }
                let matched = modes.filter { mode in
                    mode.detect.contains { sample.contains($0.lowercased()) }
                }
                for mode in matched {
                    matches.append(ProfileMatch(profile: profile, format: format, mode: mode))
                }
                if matched.isEmpty {
                    let declared = modes.isEmpty
                        ? "no mode for format \(format.id)"
                        : modes.map { "\($0.id) [\($0.detect.joined(separator: ", "))]" }.joined(separator: ", ")
                    misses.append("\(profile.relativePath): \(declared)")
                }
            }
        }
        if matches.count == 1 {
            // Only the claims whose own selectors conflict with this source —
            // or that carry no trustworthy selectors at all — block it. Claims
            // with provably unrelated signatures stay out of this diagnostic.
            let blocking = claims.filter { $0.signatures.isEmpty || $0.conflicts(sample: sample) }
            if blocking.isEmpty {
                return .matched(matches[0])
            }
            let note = "A valid profile (\(matches[0].profile.relativePath) mode \(matches[0].mode.id)) also matches this source; the source stays blocked until the invalid profile is fixed or removed."
            return .failed((blocking.flatMap(\.issues) + [note]).joined(separator: "\n"))
        }
        if matches.count > 1 {
            let described = matches.map { "\($0.profile.relativePath) mode \($0.mode.id)" }.joined(separator: ", ")
            return .failed("Ambiguous profile match: \(described). Keep one profile mode per source format.")
        }
        if !claims.isEmpty {
            let conflict = valid.isEmpty ? [] : ["A supported profile also claims \"\(fileExtension)\"; the source stays blocked until the invalid profile is fixed or removed."]
            return .failed((claims.flatMap(\.issues) + conflict).joined(separator: "\n"))
        }
        guard !valid.isEmpty else {
            return .failed("No instrument profile supports \"\(fileExtension)\" files. Add a versioned profile under data/instruments; see CONTRACT.md.")
        }

        return .failed("No mode signature matched this source. Declared modes: \(misses.joined(separator: "; ")). Add a detect signature for this file or fix the profile.")
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private enum ProfileSchema {
    static func load(text: String, relativePath: String, sha256: String) -> ProfileLoadOutcome {
        let root: YAMLNode
        do {
            root = try YAMLParser.parse(text)
        } catch let error as YAMLParseError {
            // Malformed YAML supplies no trustworthy selectors: the global issue
            // stays visible and nothing is guessed from the broken content.
            return ProfileLoadOutcome(profile: nil, issues: ["\(relativePath): YAML parse error \(error.localizedDescription)"], extensions: [], signatures: [])
        } catch {
            return ProfileLoadOutcome(profile: nil, issues: ["\(relativePath): YAML parse error \(error.localizedDescription)"], extensions: [], signatures: [])
        }
        guard root.mapEntries != nil else {
            return ProfileLoadOutcome(profile: nil, issues: ["\(relativePath): the profile document must be a mapping."], extensions: [], signatures: [])
        }
        // A nested raw_viewer block is no longer supported: a viewer profile
        // must be a standalone top-level document. The diagnostic stays
        // fail-closed with the profile path and the migration target.
        if root.value(for: "raw_viewer") != nil {
            let selectors = lenientSelectors(root)
            return ProfileLoadOutcome(profile: nil, issues: [
                "\(relativePath): raw_viewer profile blocks are not supported; move the versioned profile to a standalone top-level document (companion profiles live in data/instruments/rawview/) (see CONTRACT.md)."
            ], extensions: selectors.extensions, signatures: selectors.signatures)
        }
        let selectors = lenientSelectors(root)
        guard let versionText = root.value(for: "schema_version")?.scalarValue else {
            return ProfileLoadOutcome(profile: nil, issues: [
                "\(relativePath): profile is unversioned. Add \"schema_version: 1\" and migrate this profile to schema version 1 (see CONTRACT.md). RawView does not rewrite profiles."
            ], extensions: selectors.extensions, signatures: selectors.signatures)
        }
        guard let version = Int(versionText) else {
            return ProfileLoadOutcome(profile: nil, issues: [
                "\(relativePath): schema_version must be an integer; found \"\(versionText)\"."
            ], extensions: selectors.extensions, signatures: selectors.signatures)
        }
        guard ProfileCatalog.supportedSchemaVersions.contains(version) else {
            return ProfileLoadOutcome(profile: nil, issues: [
                "\(relativePath): unsupported schema_version \(version); this viewer supports schema_version 1 and 2."
            ], extensions: selectors.extensions, signatures: selectors.signatures)
        }
        return validate(root, relativePath: relativePath, sha256: sha256, selectors: selectors, version: version)
    }

    /// Conservative declarative evidence from a syntactically parseable profile,
    /// independent of full schema acceptance: claimed extensions plus declared
    /// detect signatures in both the v1 (`modes[].detect`) and legacy
    /// (`application_modes[].detect.signatures`) shapes. Only plain strings are
    /// kept; anything else contributes no evidence.
    private static func lenientSelectors(_ root: YAMLNode) -> (extensions: [String], signatures: [String]) {
        var extensions: [String] = []
        if let formatNodes = root.value(for: "formats")?.listItems {
            for node in formatNodes {
                guard let extensionNodes = node.value(for: "extensions")?.listItems else { continue }
                for node in extensionNodes {
                    guard let value = node.scalarValue?.lowercased(), value.hasPrefix(".") else { continue }
                    extensions.append(value)
                }
            }
        }
        var signatures: [String] = []
        if let modeNodes = root.value(for: "modes")?.listItems {
            for mode in modeNodes {
                guard let detectNodes = mode.value(for: "detect")?.listItems else { continue }
                for node in detectNodes {
                    guard let value = node.scalarValue, !value.isEmpty else { continue }
                    signatures.append(value)
                }
            }
        }
        if let modeNodes = root.value(for: "application_modes")?.listItems {
            for mode in modeNodes {
                guard let signatureNodes = mode.value(for: "detect")?.value(for: "signatures")?.listItems else { continue }
                for node in signatureNodes {
                    guard let value = node.scalarValue, !value.isEmpty else { continue }
                    signatures.append(value)
                }
            }
        }
        return (Array(Set(extensions)).sorted(), Array(Set(signatures)).sorted())
    }

    private static func validate(_ root: YAMLNode, relativePath: String, sha256: String, selectors: (extensions: [String], signatures: [String]), version: Int) -> ProfileLoadOutcome {
        let extensions = selectors.extensions
        var errors: [String] = []
        func fail(_ message: String) { errors.append("\(relativePath): \(message)") }
        func string(_ node: YAMLNode?, _ field: String) -> String? {
            guard let value = node?.scalarValue else { fail("\(field) is required."); return nil }
            return value
        }
        /// Fail-closed unknown keys: every mapping scope allowlists its schema v1
        /// fields, so a key the viewer does not understand blocks the profile
        /// with a path-precise diagnostic instead of being silently ignored.
        func rejectUnknown(_ node: YAMLNode?, allowed: Set<String>, scope: String, skipping skipped: Set<String> = []) {
            guard let entries = node?.mapEntries else { return }
            for entry in entries where !allowed.contains(entry.key) && !skipped.contains(entry.key) {
                if scope.isEmpty {
                    fail("unknown key \"\(entry.key)\" is not part of schema v\(version).")
                } else {
                    fail("\(scope).\(entry.key) is not part of schema v\(version) (unknown key).")
                }
            }
        }
        func stringList(_ node: YAMLNode?, _ field: String) -> [String]? {
            // Fail-closed string lists: a non-scalar element is a schema error, not a silent drop.
            guard let node else { return nil }
            guard let items = node.listItems else { fail("\(field) must be a list."); return nil }
            var result: [String] = []
            for item in items {
                guard let value = item.scalarValue else {
                    fail("\(field) must contain only strings; found a non-scalar entry.")
                    return nil
                }
                result.append(value)
            }
            return result
        }

        // Schema v1 has no transforms mechanism (CONTRACT.md): any declared
        // transforms field, regardless of YAML node shape, blocks the profile
        // with an actionable diagnostic instead of being silently ignored.
        if root.value(for: "transforms") != nil {
            fail("transforms are not part of schema v\(version); remove the transforms field or migrate the profile (see CONTRACT.md).")
        }
        rejectUnknown(root, allowed: ["schema_version", "instrument", "formats", "modes"], scope: "")

        guard let instrumentNode = root.value(for: "instrument"), instrumentNode.mapEntries != nil else {
            fail("instrument mapping is required.")
            return ProfileLoadOutcome(profile: nil, issues: errors, extensions: extensions, signatures: selectors.signatures)
        }
        rejectUnknown(instrumentNode, allowed: ["id", "name", "vendor", "model"], scope: "instrument")
        let instrumentID = string(instrumentNode.value(for: "id"), "instrument.id")
        let instrumentName = string(instrumentNode.value(for: "name"), "instrument.name")
        let vendor = instrumentNode.value(for: "vendor")?.scalarValue
        let model = instrumentNode.value(for: "model")?.scalarValue

        var formats: [ProfileFormat] = []
        var formatIDs = Set<String>()
        let formatNodes = root.value(for: "formats")?.listItems ?? []
        if formatNodes.isEmpty { fail("formats must contain at least one format.") }
        for (index, node) in formatNodes.enumerated() {
            let field = "formats[\(index)]"
            guard node.mapEntries != nil else { fail("\(field) must be a mapping."); continue }
            guard let id = string(node.value(for: "id"), "\(field).id") else { continue }
            if !formatIDs.insert(id).inserted { fail("\(field).id \"\(id)\" is duplicated.") }
            if node.value(for: "transforms") != nil {
                fail("\(field).transforms are not part of schema v\(version); remove the field (see CONTRACT.md).")
            }
            // Schema v1 supports row-block `tabular`; schema v2 adds the
            // headerless positional `comment-tsv` layout.
            let supportedKinds = version >= 2 ? ["tabular", "comment-tsv"] : ["tabular"]
            let kind: String
            if let found = node.value(for: "kind")?.scalarValue, supportedKinds.contains(found) {
                kind = found
            } else if node.value(for: "kind")?.scalarValue == nil {
                fail("\(field).kind is required and must be \(supportedKinds.map { "\"\($0)\"" }.joined(separator: ", ")).")
                continue
            } else {
                fail("\(field).kind \"\(node.value(for: "kind")?.scalarValue ?? "")\" is not supported; this viewer supports \(supportedKinds.map { "\"\($0)\"" }.joined(separator: ", ")).")
                continue
            }
            let allowedKeys: Set<String> = kind == "comment-tsv"
                ? ["id", "kind", "extensions", "delimiter", "encoding", "columns", "decimal"]
                : ["id", "kind", "extensions", "delimiter", "encoding", "rows", "columns", "decimal"]
            rejectUnknown(node, allowed: allowedKeys, scope: field, skipping: ["transforms"])
            guard let extensionValues = stringList(node.value(for: "extensions"), "\(field).extensions") else {
                if node.value(for: "extensions") == nil { fail("\(field).extensions must list at least one file extension such as \".csv\".") }
                continue
            }
            if extensionValues.isEmpty { fail("\(field).extensions must list at least one file extension such as \".csv\".") }
            for value in extensionValues where !value.hasPrefix(".") {
                fail("\(field).extensions entry \"\(value)\" must start with \".\".")
            }
            guard let delimiterText = string(node.value(for: "delimiter"), "\(field).delimiter"), delimiterText.count == 1 else {
                if node.value(for: "delimiter")?.scalarValue != nil { fail("\(field).delimiter must be a single character.") }
                continue
            }
            // Schema v1 has no decimal mechanism: the field is rejected there
            // rather than silently accepted. A comma decimal needs a non-comma
            // delimiter, otherwise cells cannot be split unambiguously.
            var decimalSeparator: Character = "."
            if let decimalNode = node.value(for: "decimal") {
                guard version >= 2 else {
                    fail("\(field).decimal is not part of schema v1 (no decimal mechanism; see CONTRACT.md).")
                    continue
                }
                guard let text = decimalNode.scalarValue, text.count == 1, text == "." || text == "," else {
                    fail("\(field).decimal must be \".\" or \",\".")
                    continue
                }
                decimalSeparator = Character(text)
            }
            if delimiterText == "," && decimalSeparator == "," {
                fail("\(field).decimal \",\" conflicts with delimiter \",\"; European decimals require a non-comma delimiter.")
                continue
            }
            let encodingNames: [String]
            if let encodingNode = node.value(for: "encoding") {
                guard let parsed = stringList(encodingNode, "\(field).encoding") else { continue }
                encodingNames = parsed
            } else {
                encodingNames = ["utf-8"]
            }
            var encodings: [String.Encoding] = []
            for name in encodingNames {
                guard let encoding = encoding(named: name) else {
                    fail("\(field).encoding entry \"\(name)\" is not supported; use utf-8, windows-1252, iso-8859-1, or ascii.")
                    continue
                }
                encodings.append(encoding)
            }
            let namesPrefix: String?
            let dataPrefix: String?
            if kind == "comment-tsv" {
                if node.value(for: "rows") != nil {
                    fail("\(field).rows is not part of kind \"comment-tsv\" (headerless positional layout); remove the rows mapping.")
                    continue
                }
                namesPrefix = nil
                dataPrefix = nil
            } else {
                guard let rows = node.value(for: "rows"), rows.mapEntries != nil else {
                    fail("\(field).rows mapping is required.")
                    continue
                }
                rejectUnknown(rows, allowed: ["names_prefix", "data_prefix"], scope: "\(field).rows")
                namesPrefix = string(rows.value(for: "names_prefix"), "\(field).rows.names_prefix")
                // An empty v2 data_prefix matches every non-blank line after the
                // header row (Keithley LVM rows carry an empty leading cell).
                // Schema v1 still requires a non-empty marker.
                if version >= 2, let marker = rows.value(for: "data_prefix") {
                    guard case .scalar(let text) = marker else {
                        fail("\(field).rows.data_prefix must be a string.")
                        continue
                    }
                    dataPrefix = text
                } else {
                    dataPrefix = string(rows.value(for: "data_prefix"), "\(field).rows.data_prefix")
                }
            }
            var columns: [ProfileColumn] = []
            var columnKeys = Set<String>()
            // Positional layouts resolve columns by source index; two channels
            // sharing one source column is ambiguous and blocked here.
            var indexOwners: [Int: String] = [:]
            let columnEntries = node.value(for: "columns")?.mapEntries ?? []
            if columnEntries.isEmpty { fail("\(field).columns must declare at least one column.") }
            for entry in columnEntries {
                let columnField = "\(field).columns.\(entry.key)"
                guard entry.value.mapEntries != nil else { fail("\(columnField) must be a mapping."); continue }
                if kind == "comment-tsv" {
                    rejectUnknown(entry.value, allowed: ["column_index", "quantity", "unit", "label"], scope: columnField)
                    if !columnKeys.insert(entry.key).inserted { fail("\(columnField) is duplicated.") }
                    guard let indexText = entry.value.value(for: "column_index")?.scalarValue,
                          let columnIndex = Int(indexText), columnIndex >= 0 else {
                        fail("\(columnField).column_index must be a non-negative integer.")
                        continue
                    }
                    if let owner = indexOwners[columnIndex] {
                        fail("\(field).columns.\(owner) and \(columnField) resolve to the same source column \(columnIndex + 1).")
                        continue
                    }
                    indexOwners[columnIndex] = entry.key
                    let quantity = string(entry.value.value(for: "quantity"), "\(columnField).quantity")
                    let unit = string(entry.value.value(for: "unit"), "\(columnField).unit")
                    let label = entry.value.value(for: "label")?.scalarValue ?? humanized(entry.key)
                    guard let quantity, let unit else { continue }
                    columns.append(ProfileColumn(key: entry.key, header: nil, aliases: [], quantity: quantity, unit: unit, label: label, index: columnIndex, required: true))
                    continue
                }
                // Schema v2 tabular columns may declare an optional channel
                // (`required: false`); schema v1 and headerless layouts reject
                // the key as unknown, unchanged.
                var columnAllowed: Set<String> = ["header", "aliases", "quantity", "unit", "label"]
                if version >= 2 { columnAllowed.insert("required") }
                rejectUnknown(entry.value, allowed: columnAllowed, scope: columnField)
                if !columnKeys.insert(entry.key).inserted { fail("\(columnField) is duplicated.") }
                let header = string(entry.value.value(for: "header"), "\(columnField).header")
                let quantity = string(entry.value.value(for: "quantity"), "\(columnField).quantity")
                let unit = string(entry.value.value(for: "unit"), "\(columnField).unit")
                let label = entry.value.value(for: "label")?.scalarValue ?? humanized(entry.key)
                let aliases: [String]
                if let aliasesNode = entry.value.value(for: "aliases") {
                    guard let parsed = stringList(aliasesNode, "\(columnField).aliases") else { continue }
                    aliases = parsed
                } else {
                    aliases = []
                }
                guard let header, let quantity, let unit else { continue }
                var isRequired = true
                if version >= 2, let requiredNode = entry.value.value(for: "required") {
                    guard let text = requiredNode.scalarValue, text == "true" || text == "false" else {
                        fail("\(columnField).required must be \"true\" or \"false\".")
                        continue
                    }
                    isRequired = text == "true"
                }
                columns.append(ProfileColumn(key: entry.key, header: header, aliases: aliases, quantity: quantity, unit: unit, label: label, index: nil, required: isRequired))
            }
            if kind == "tabular" {
                guard namesPrefix != nil, dataPrefix != nil else { continue }
            }
            formats.append(ProfileFormat(id: id, kind: kind, extensions: extensionValues.map { $0.lowercased() },
                                         delimiter: Character(delimiterText), encodings: encodings,
                                         encodingNames: encodingNames, decimalSeparator: decimalSeparator,
                                         namesPrefix: namesPrefix, dataPrefix: dataPrefix,
                                         columns: columns))
        }

        var modes: [ProfileMode] = []
        var modeIDs = Set<String>()
        let modeNodes = root.value(for: "modes")?.listItems ?? []
        if modeNodes.isEmpty { fail("modes must contain at least one application mode.") }
        for (index, node) in modeNodes.enumerated() {
            let field = "modes[\(index)]"
            guard node.mapEntries != nil else { fail("\(field) must be a mapping."); continue }
            guard let id = string(node.value(for: "id"), "\(field).id") else { continue }
            if !modeIDs.insert(id).inserted { fail("\(field).id \"\(id)\" is duplicated.") }
            guard let formatID = string(node.value(for: "format"), "\(field).format") else { continue }
            let format = formats.first { $0.id == formatID }
            if format == nil { fail("\(field).format \"\(formatID)\" does not match any format id.") }
            if node.value(for: "transforms") != nil {
                fail("\(field).transforms are not part of schema v\(version); remove the field (see CONTRACT.md).")
            }
            rejectUnknown(node, allowed: ["id", "format", "detect", "extract"], scope: field, skipping: ["transforms"])
            let detect: [String]
            if let detectNode = node.value(for: "detect") {
                guard let parsed = stringList(detectNode, "\(field).detect") else { continue }
                detect = parsed.filter { !$0.isEmpty }
            } else {
                detect = []
            }
            if detect.isEmpty { fail("\(field).detect must list at least one header signature string.") }
            guard let extract = node.value(for: "extract"), let extractEntries = extract.mapEntries else {
                fail("\(field).extract mapping with x and y is required.")
                continue
            }
            for entry in extractEntries where entry.key != "x" && entry.key != "y" {
                fail("\(field).extract.\(entry.key) is not part of schema v\(version); only x and y are supported (see CONTRACT.md).")
            }
            guard let x = string(extract.value(for: "x"), "\(field).extract.x") else { continue }
            let y: [String]
            if let yNode = extract.value(for: "y") {
                guard let parsed = stringList(yNode, "\(field).extract.y") else { continue }
                y = parsed
            } else {
                y = []
            }
            if y.isEmpty { fail("\(field).extract.y must name at least one column.") }
            if Set(y).count != y.count { fail("\(field).extract.y contains duplicated columns.") }
            if let format {
                if format.column(named: x) == nil { fail("\(field).extract.x \"\(x)\" is not a column of format \"\(format.id)\".") }
                for key in y where format.column(named: key) == nil {
                    fail("\(field).extract.y \"\(key)\" is not a column of format \"\(format.id)\".")
                }
                // Plot axes need guaranteed values: an optional channel may be
                // absent from a source, so it cannot drive x or y.
                if let xColumn = format.column(named: x), !xColumn.required {
                    fail("\(field).extract.x \"\(x)\" is an optional column; plot axes must reference required columns.")
                }
                for key in y {
                    if let yColumn = format.column(named: key), !yColumn.required {
                        fail("\(field).extract.y \"\(key)\" is an optional column; plot axes must reference required columns.")
                    }
                }
            }
            if y.contains(x) { fail("\(field).extract.x \"\(x)\" must not also appear in extract.y.") }
            modes.append(ProfileMode(id: id, formatID: formatID, detect: detect, x: x, y: y))
        }

        guard errors.isEmpty, let instrumentID, let instrumentName else {
            return ProfileLoadOutcome(profile: nil, issues: errors.isEmpty ? ["\(relativePath): profile is incomplete."] : errors, extensions: extensions, signatures: selectors.signatures)
        }
        let profile = InstrumentProfile(instrumentID: instrumentID, instrumentName: instrumentName,
                                        vendor: vendor, model: model, formats: formats, modes: modes,
                                        relativePath: relativePath, sha256: sha256, schemaVersion: version)
        return ProfileLoadOutcome(profile: profile, issues: [], extensions: extensions, signatures: [])
    }

    private static func encoding(named name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": .utf8
        case "windows-1252", "cp1252": .windowsCP1252
        case "iso-8859-1", "latin-1", "latin1": .isoLatin1
        case "ascii", "us-ascii": .ascii
        default: nil
        }
    }

    private static func humanized(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
