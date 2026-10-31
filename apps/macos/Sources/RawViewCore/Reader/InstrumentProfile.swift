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
    /// Schema v2 only, nil when absent: every token must occur
    /// as an exact basename token (case-sensitive).
    let filenameContainsAll: [String]?
    let when: ProfileWhenMatcher.WhenClause
    let x: String
    let y: [String]
}

struct InstrumentProfile: Sendable, Equatable {
    let profileID: String
    let instrumentID: String
    let instrumentName: String
    let vendor: String?
    let model: String?
    let formats: [ProfileFormat]
    let modes: [ProfileMode]
    let relativePath: String
    let sha256: String
    let schemaVersion: Int
    let profileWhen: ProfileWhenMatcher.WhenClause?
}

struct ProfileMatch: Sendable {
    let profile: InstrumentProfile
    let format: ProfileFormat
    let mode: ProfileMode
}

enum ProfileResolution: Sendable {
    case matched(ProfileMatch)
    case failed(String)
    case ambiguousProfile(candidateIDs: [String])
    case grammarMatchedNoProfile

    var resolveCode: ProfileWhenMatcher.ProfileResolveCode? {
        switch self {
        case .ambiguousProfile: return .ambiguousProfile
        case .grammarMatchedNoProfile: return .grammarMatchedNoProfile
        default: return nil
        }
    }
}

/// Per-mode selector evidence from one syntactically parseable mode of a
/// schema-invalid profile. A nil filename list means the mode declares no
/// usable filename evidence (absent, ignored outside schema v2, or
/// malformed): it proves nothing either way. An empty signature list means
/// header evidence is missing. Only a trustworthy selector proving a mismatch
/// makes the mode unrelated to a source.
struct BrokenModeSelectors: Sendable {
    /// Well-formed filename tokens; meaningful only for schema v2 claims.
    let filenames: [String]?
    /// Complete-list header signatures: the whole detect value was a list of
    /// scalar strings with at least one non-empty survivor. Empty means the
    /// evidence is missing or malformed and proves nothing.
    let signatures: [String]
}

struct BrokenClaim: Sendable {
    /// A syntactically parseable but schema-invalid profile, kept whole: its
    /// selectors and diagnostics are never mixed with another profile's, so one
    /// broken profile cannot borrow another's signatures. Each mode is judged
    /// on its own selectors: the profile blocks a source when any mode could
    /// still conflict with it.
    let relativePath: String
    let extensions: [String]
    let issues: [String]
    let modeSelectors: [BrokenModeSelectors]
    /// SHA-256 of the profile's raw bytes: invalid profile content is part of
    /// the catalog fingerprint even when no selectors were parsed.
    let contentSHA256: String

    /// Per-source conflict using this profile's own selectors only. A mode is
    /// unrelated when a trustworthy selector proves mismatch: a valid filename
    /// list missing any token from the basename, or a complete trustworthy
    /// detect list with no signature in the header sample. Anything else — a
    /// match on both sides, or uncertainty from a malformed/missing selector
    /// (including a detect list that mixes scalars with non-scalars) — keeps
    /// the source blocked. A filename match plus missing detect is uncertain
    /// and blocks; a header match plus malformed filename is uncertain and
    /// blocks. A claim with no mode evidence at all blocks fail-closed.
    func blocks(sample: String, basename: String) -> Bool {
        if modeSelectors.isEmpty { return true }
        let sampleLower = sample.lowercased()
        let have = Set(ProfileWhenMatcher.tokenizeBasename(basename))
        for mode in modeSelectors {
            let filenameMismatch = mode.filenames.map { tokens in
                !ProfileWhenMatcher.splitLegacyFilenameTokens(tokens).allSatisfy { have.contains($0) }
            } ?? false
            let headerMismatch = !mode.signatures.isEmpty
                && !mode.signatures.contains { sampleLower.contains($0.lowercased()) }
            if !filenameMismatch && !headerMismatch { return true }
        }
        return false
    }
}

struct ProfileLoadOutcome: Sendable {
    let profile: InstrumentProfile?
    let issues: [String]
    let extensions: [String]
    /// Per-mode lenient selector evidence from a syntactically parseable but
    /// schema-invalid profile. Malformed YAML supplies no selectors.
    let modeSelectors: [BrokenModeSelectors]
    /// A structurally valid schema-v3 variant document. Never set alongside
    /// `profile`: one file yields one catalog entry of one schema.
    var v3Document: LoadedV3Document? = nil
}

/// One validated schema-v3 profile document with its project-relative path
/// and exact source bytes digest. The digest (not the parsed struct) is the
/// cache-identity material, so any byte edit invalidates cached results.
public struct LoadedV3Document: Sendable, Equatable {
    public let document: ProfileDocumentV3
    public let relativePath: String
    public let sha256: String
}

struct ProfileCatalog: Sendable {
    static let supportedSchemaVersions = [1, 2]
    static let maximumProfileBytes = 1 << 20

    let profiles: [InstrumentProfile]
    let issues: [String]
    let brokenClaims: [BrokenClaim]
    /// Validated schema-v3 variant documents from the same directory scan,
    /// merged with the legacy profiles rather than hiding them. A document
    /// carrying `legacy_origin` suppresses only its exact unchanged companion
    /// (same path AND bytes); unrelated peers always stay visible.
    var v3Documents: [LoadedV3Document] = []

    /// Stable digest over the complete loaded catalog — valid profiles (file
    /// content digests), broken claims (raw bytes digest + selectors), and
    /// issues — encoded with Foundation `JSONEncoder` (`.sortedKeys`, so the
    /// emitted bytes are deterministic) over ordered components; user-controlled
    /// fields cannot alias fingerprint fields because every component is a
    /// JSON string. Profile parse behavior depends only on file bytes, so
    /// content digests characterize the parsed state exactly.
    var fingerprint: String {
        struct ValidMaterial: Codable {
            var path: String
            var contentSHA256: String
            var schemaVersion: Int
            var instrumentID: String
        }
        struct BrokenModeMaterial: Codable {
            var filenames: [String]?
            var signatures: [String]
        }
        struct BrokenMaterial: Codable {
            var path: String
            var contentSHA256: String
            var extensions: [String]
            var modes: [BrokenModeMaterial]
        }
        struct V3Material: Codable {
            var path: String
            var contentSHA256: String
            var profileID: String
        }
        struct CatalogMaterial: Codable {
            var valid: [ValidMaterial]
            var broken: [BrokenMaterial]
            var v3: [V3Material]
            var issues: [String]
        }
        let material = CatalogMaterial(
            valid: profiles.map { profile in
                ValidMaterial(path: profile.relativePath, contentSHA256: profile.sha256,
                              schemaVersion: profile.schemaVersion, instrumentID: profile.instrumentID)
            },
            broken: brokenClaims.map { claim in
                BrokenMaterial(path: claim.relativePath, contentSHA256: claim.contentSHA256,
                               extensions: claim.extensions,
                               modes: claim.modeSelectors.map { selector in
                                   BrokenModeMaterial(filenames: selector.filenames, signatures: selector.signatures)
                               })
            },
            v3: v3Documents.map { loaded in
                V3Material(path: loaded.relativePath, contentSHA256: loaded.sha256,
                           profileID: loaded.document.profileID)
            },
            issues: issues)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try? encoder.encode(material)
        return sha256Hex(encoded ?? Data())
    }

    static func load(project: ProjectContext) -> ProfileCatalog {
        // Priority 1: <project>/.rawviewer/instrument/
        let rawviewerRoot = project.root.appendingPathComponent(".rawviewer/instrument", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        if isDirectoryWithYAMLs(rawviewerRoot, within: project.root) {
            return loadProfiles(from: rawviewerRoot, displayRoot: ".rawviewer/instrument", project: project)
        }

        // Priority 2: <project>/data/.rawview/instrument/
        let legacyRawviewRoot = project.root.appendingPathComponent("data/.rawview/instrument", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        if isDirectoryWithYAMLs(legacyRawviewRoot, within: project.root) {
            return loadProfiles(from: legacyRawviewRoot, displayRoot: "data/.rawview/instrument", project: project)
        }

        // Priority 3: <project>/data/instruments/
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
            guard (companionStat.st_mode & S_IFMT) != S_IFLNK else {
                return ProfileCatalog(profiles: [], issues: ["data/instruments/rawview is a symlink; profiles must be regular entries in the companion directory."], brokenClaims: [])
            }
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

    private static func isDirectoryWithYAMLs(_ url: URL, within projectRoot: URL) -> Bool {
        var statInfo = stat()
        guard lstat(url.path, &statInfo) == 0 else { return false }
        guard (statInfo.st_mode & S_IFMT) != S_IFLNK else { return false }
        guard url.path.hasPrefix(projectRoot.path + "/") || url.path == projectRoot.path else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else { return false }
        return hasYAMLProfiles(at: url)
    }

    private static func hasYAMLProfiles(at root: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return false }
        return entries.contains { entry in
            let lower = entry.lowercased()
            return lower.hasSuffix(".yaml") || lower.hasSuffix(".yml")
        }
    }

    private static func loadProfiles(from root: URL, displayRoot: String, project: ProjectContext) -> ProfileCatalog {
        var profiles: [InstrumentProfile] = []
        var issues: [String] = []
        var brokenClaims: [BrokenClaim] = []
        var v3Documents: [LoadedV3Document] = []
        let canonicalProfileRoot = SecureFile.kernelCanonical(root.path)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )) ?? []

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fileExtension = entry.pathExtension.lowercased()
            guard fileExtension == "yaml" || fileExtension == "yml" else { continue }
            // Directories (including any archive directory) are never
            // profiles and stay silent; only top-level YAML files load.
            var entryIsDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &entryIsDirectory),
               entryIsDirectory.boolValue { continue }
            // Clear diagnostic for a claimed symlink; the open below is the gate.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) != nil {
                issues.append("\(displayRoot)/\(entry.lastPathComponent): profile is a symlink; symlinks are never followed; skipped.")
                continue
            }
            guard let claimedRelative = project.relativePath(of: entry) else {
                issues.append("\(displayRoot)/\(entry.lastPathComponent): profile is outside this project; skipped.")
                continue
            }
            // Open the claimed path itself before any resolution; the
            // descriptor pins the exact object and its canonical path is
            // checked before any byte read.
            let handle: FileHandle
            do {
                handle = try SecureFile.openVerified(resolvedPath: entry.path, beneath: project.root.path)
            } catch let error as SecureOpenError {
                issues.append(error.profileIssue(display: "\(displayRoot)/\(entry.lastPathComponent)"))
                continue
            } catch {
                issues.append("\(claimedRelative): profile could not be opened: \(error.localizedDescription); skipped.")
                continue
            }
            guard let actualPath = SecureFile.canonicalPath(of: handle) else {
                try? handle.close()
                issues.append("\(claimedRelative): profile is not readable; skipped.")
                continue
            }
            let actualParent = URL(fileURLWithPath: actualPath).deletingLastPathComponent().path
            guard actualParent == canonicalProfileRoot else {
                try? handle.close()
                issues.append("\(claimedRelative): profile resolves outside \(displayRoot); skipped.")
                continue
            }
            var fileStat = stat()
            guard fstat(handle.fileDescriptor, &fileStat) == 0,
                  (fileStat.st_mode & S_IFMT) == S_IFREG else {
                try? handle.close()
                issues.append("\(claimedRelative): profile is not a readable regular file; skipped.")
                continue
            }
            let relativePath = claimedRelative
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
            } else if let v3 = outcome.v3Document {
                v3Documents.append(v3)
            } else {
                issues.append(contentsOf: outcome.issues)
                if !outcome.extensions.isEmpty {
                    brokenClaims.append(BrokenClaim(relativePath: relativePath, extensions: outcome.extensions,
                                                    issues: outcome.issues, modeSelectors: outcome.modeSelectors,
                                                    contentSHA256: sha256Hex(raw)))
                }
            }
        }
        // Canonical legacy-origin shadowing: a v3 document suppresses only
        // its exact unchanged companion (same project-relative path AND same
        // bytes). A changed companion stays visible beside the v3 document
        // with a conflict diagnostic; unrelated peers are never touched. An
        // instrument ID alone never suppresses anything.
        var shadowedIndexes: [Int] = []
        for loaded in v3Documents {
            guard let origin = loaded.document.legacyOrigin,
                  let index = profiles.firstIndex(where: { $0.relativePath == origin.path }) else { continue }
            if profiles[index].sha256 == origin.sha256 {
                shadowedIndexes.append(index)
            } else {
                issues.append("\(loaded.relativePath): legacy_origin \(origin.path) changed since import (bytes differ); both the v3 document and the legacy profile stay visible.")
            }
        }
        for index in shadowedIndexes.sorted(by: >) {
            profiles.remove(at: index)
        }
        return ProfileCatalog(profiles: profiles, issues: issues, brokenClaims: brokenClaims, v3Documents: v3Documents)
    }

    func hasBrokenClaim(for fileExtension: String) -> Bool {
        brokenClaims.contains { $0.extensions.contains(fileExtension) }
    }

    func hasValidClaim(for fileExtension: String) -> Bool {
        profiles.contains { $0.formats.contains { $0.extensions.contains(fileExtension) } }
    }

    /// Resolves one source by extension, bounded header sample, and basename.
    /// Every failure message names the profile(s) and field or signature that
    /// would fix it. A v2 mode matches only when its filename selector (when
    /// present) matches the basename AND a detect signature occurs in the
    /// header sample. Per-source isolation: a uniquely matched valid source
    /// stays usable beside an invalid profile claiming the same extension only
    /// when every mode of that profile is proven unrelated by its own
    /// trustworthy selectors — a valid filename list missing a basename token,
    /// or a valid non-empty detect list with no header match. A mode that
    /// could still conflict (both sides match, or uncertainty from a
    /// malformed/missing selector) keeps the source blocked instead of claiming
    /// a unique mapping. Filename evidence counts only for declared schema v2
    /// claims; other claims fall back to header evidence alone.
    func resolve(
        extension fileExtension: String,
        headerSample: String,
        basename: String,
        grammar: ProfileWhenMatcher.GrammarMatchContext
    ) -> ProfileResolution {
        let valid = profiles.filter { profile in
            profile.formats.contains { $0.extensions.contains(fileExtension) }
        }
        let claims = brokenClaims.filter { $0.extensions.contains(fileExtension) }

        let basenameTokens = ProfileWhenMatcher.tokenizeBasename(basename)
        let grammarFields = grammar.matchedFields
        let sampleLower = headerSample.lowercased()
        var matches: [ProfileMatch] = []
        var misses: [String] = []
        var sawFilenameGate = false
        for profile in valid {
            let profileWhen = profile.profileWhen
            for format in profile.formats where format.extensions.contains(fileExtension) {
                let modes = profile.modes.filter { $0.formatID == format.id }
                if modes.contains(where: { !$0.when.filenameTokens.isEmpty }) { sawFilenameGate = true }
                for mode in modes {
                    let merged = ProfileWhenMatcher.mergeWhen(profile: profileWhen, variant: mode.when)
                    guard ProfileWhenMatcher.modeIsCandidate(merged, grammar: grammar) else { continue }
                    if ProfileWhenMatcher.matchesWhen(
                        merged,
                        grammarFields: grammarFields,
                        basenameTokens: basenameTokens,
                        headerSample: headerSample,
                        basenameForContent: basename
                    ) {
                        matches.append(ProfileMatch(profile: profile, format: format, mode: mode))
                    }
                }
                let profileHits = matches.filter { $0.profile.relativePath == profile.relativePath }
                if profileHits.isEmpty {
                    let considered = modes.filter {
                        ProfileWhenMatcher.modeIsCandidate(
                            ProfileWhenMatcher.mergeWhen(profile: profileWhen, variant: $0.when),
                            grammar: grammar)
                    }
                    guard !considered.isEmpty else { continue }
                    let declared = considered.map {
                        describeMiss($0, basename: basename, sample: sampleLower, profileWhen: profileWhen)
                    }.joined(separator: ", ")
                    misses.append("\(profile.relativePath): \(declared)")
                }
            }
        }
        if matches.count >= 2 {
            var candidateIDs = matches.map { ProfileWhenMatcher.candidateProfileID($0.profile) }.sorted()
            candidateIDs = Array(Set(candidateIDs)).sorted()
            return .ambiguousProfile(candidateIDs: candidateIDs)
        }
        if matches.count == 1 {
            let blocking = claims.filter { $0.blocks(sample: sampleLower, basename: basename) }
            if blocking.isEmpty {
                return .matched(matches[0])
            }
            let note = "A valid profile (\(matches[0].profile.relativePath) mode \(matches[0].mode.id)) also matches this source; the source stays blocked until the invalid profile is fixed or removed."
            return .failed((blocking.flatMap(\.issues) + [note]).joined(separator: "\n"))
        }
        if grammar.catalogLoaded && grammar.grammarMatched {
            return .grammarMatchedNoProfile
        }
        if !claims.isEmpty {
            let conflict = valid.isEmpty ? [] : ["A supported profile also claims \"\(fileExtension)\"; the source stays blocked until the invalid profile is fixed or removed."]
            return .failed((claims.flatMap(\.issues) + conflict).joined(separator: "\n"))
        }
        guard !valid.isEmpty else {
            return .failed("No instrument profile supports \"\(fileExtension)\" files. Add a versioned profile under data/instruments; see CONTRACT.md.")
        }
        let advice = sawFilenameGate
            ? "A v2 mode with filename_contains_all needs every token in the basename and one detect signature in the first 64 KiB."
            : "Add a detect signature for this file or fix the profile."
        return .failed("No profile mode matched this source (basename \"\(basename)\"). Declared modes: \(misses.joined(separator: "; ")). \(advice)")
    }

    private func describeMiss(
        _ mode: ProfileMode,
        basename: String,
        sample: String,
        profileWhen: ProfileWhenMatcher.WhenClause?
    ) -> String {
        let merged = ProfileWhenMatcher.mergeWhen(profile: profileWhen, variant: mode.when)
        var parts: [String] = []
        if !merged.filenameTokens.isEmpty {
            parts.append(ProfileWhenMatcher.describeFilenameMiss(tokens: merged.filenameTokens, basename: basename))
        }
        if !merged.contentContainsAny.isEmpty {
            parts.append(ProfileWhenMatcher.describeContentMiss(merged, sample: sample))
        }
        return "\(mode.id) [\(parts.joined(separator: "; "))]"
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum ProfileSchema {
    private struct Selectors {
        let extensions: [String]
        let modeSelectors: [BrokenModeSelectors]
    }

    static func load(text: String, relativePath: String, sha256: String) -> ProfileLoadOutcome {
        func emptyOutcome(_ issues: [String]) -> ProfileLoadOutcome {
            ProfileLoadOutcome(profile: nil, issues: issues, extensions: [], modeSelectors: [])
        }
        let root: YAMLNode
        do {
            root = try YAMLParser.parse(text, allowIndentlessSequences: false)
        } catch let error as YAMLParseError {
            // Malformed YAML supplies no trustworthy selectors: the global issue
            // stays visible and nothing is guessed from the broken content.
            return emptyOutcome(["\(relativePath): YAML parse error \(error.localizedDescription)"])
        } catch {
            return emptyOutcome(["\(relativePath): YAML parse error \(error.localizedDescription)"])
        }
        guard root.mapEntries != nil else {
            return emptyOutcome(["\(relativePath): the profile document must be a mapping."])
        }
        // Only a declared schema_version 2 gives filename_contains_all meaning:
        // for v1, unversioned, malformed-version, and unsupported-version claims
        // the unknown key is ignored as selector evidence while header evidence
        // is preserved.
        let declaredVersion = root.value(for: "schema_version")?.scalarValue.flatMap(Int.init)
        let selectors = lenientSelectors(root, filenameTrusted: declaredVersion == 2)
        // A nested raw_viewer block is no longer supported: a viewer profile
        // must be a standalone top-level document. The diagnostic stays
        // fail-closed with the profile path and the migration target.
        if root.value(for: "raw_viewer") != nil {
            return ProfileLoadOutcome(profile: nil, issues: [
                "\(relativePath): raw_viewer profile blocks are not supported; move the versioned profile to a standalone top-level document (companion profiles live in data/instruments/rawview/) (see CONTRACT.md)."
            ], extensions: selectors.extensions, modeSelectors: selectors.modeSelectors)
        }
        func broken(_ issues: [String]) -> ProfileLoadOutcome {
            ProfileLoadOutcome(profile: nil, issues: issues, extensions: selectors.extensions, modeSelectors: selectors.modeSelectors)
        }
        guard let versionText = root.value(for: "schema_version")?.scalarValue else {
            return broken([
                "\(relativePath): profile is unversioned. Add \"schema_version: 1\" and migrate this profile to schema version 1 (see CONTRACT.md). RawView does not rewrite profiles."
            ])
        }
        guard let version = Int(versionText) else {
            return broken([
                "\(relativePath): schema_version must be an integer; found \"\(versionText)\"."
            ])
        }
        if version == 3 {
            return loadV3Document(root: root, relativePath: relativePath, sha256: sha256)
        }
        if version == 4 {
            return loadV4Document(root: root, relativePath: relativePath, sha256: sha256)
        }
        guard ProfileCatalog.supportedSchemaVersions.contains(version) else {
            return broken([
                "\(relativePath): unsupported schema_version \(version); this viewer supports schema_version 1, 2, 3, and 4."
            ])
        }
        return validate(root, relativePath: relativePath, sha256: sha256, selectors: selectors, version: version)
    }

    private static func loadV4Document(root: YAMLNode, relativePath: String, sha256: String) -> ProfileLoadOutcome {
        do {
            let document = try ProfileV4Codec.decode(root)
            try ProfileV4Codec.validateStructure(document)
            let profile = try ProfileV4Codec.compileInstrumentProfile(document, relativePath: relativePath, sha256: sha256)
            let extensions = Array(Set(profile.formats.flatMap(\.extensions))).sorted()
            return ProfileLoadOutcome(profile: profile, issues: [], extensions: extensions, modeSelectors: [])
        } catch let error as ProfileV4Error {
            return ProfileLoadOutcome(
                profile: nil, issues: ["\(relativePath): \(error.localizedDescription)"],
                extensions: ProfileV4Codec.lenientV4Extensions(root), modeSelectors: [])
        } catch {
            return ProfileLoadOutcome(
                profile: nil, issues: ["\(relativePath): \(error.localizedDescription)"],
                extensions: ProfileV4Codec.lenientV4Extensions(root), modeSelectors: [])
        }
    }

    /// Schema-v3 variant documents: structural decode plus structural
    /// validation (no grammar catalog here; references resolve at read time).
    /// A valid document joins the catalog; an invalid-but-shaped one becomes
    /// a fail-closed broken claim over its declared extensions.
    private static func loadV3Document(root: YAMLNode, relativePath: String, sha256: String) -> ProfileLoadOutcome {
        do {
            let document = try ProfileV3Codec.decode(root)
            try ProfileV3Codec.validateStructure(document)
            return ProfileLoadOutcome(profile: nil, issues: [], extensions: [], modeSelectors: [],
                                      v3Document: LoadedV3Document(document: document, relativePath: relativePath, sha256: sha256))
        } catch let error as ProfileDocumentError {
            return ProfileLoadOutcome(profile: nil, issues: ["\(relativePath): \(error.localizedDescription)"],
                                      extensions: lenientV3Extensions(root), modeSelectors: [], v3Document: nil)
        } catch {
            return ProfileLoadOutcome(profile: nil, issues: ["\(relativePath): \(error.localizedDescription)"],
                                      extensions: lenientV3Extensions(root), modeSelectors: [], v3Document: nil)
        }
    }

    /// Declared stream extensions from a schema-v3 document, whatever else is
    /// wrong with it. Lenient on purpose: only lowercase dot-prefixed scalar
    /// strings count, so a broken v3 file still blocks exactly the extensions
    /// it claims and nothing else.
    private static func lenientV3Extensions(_ root: YAMLNode) -> [String] {
        var extensions: [String] = []
        guard let variantNodes = root.value(for: "variants")?.listItems else { return [] }
        for variant in variantNodes {
            guard let extensionNodes = variant.value(for: "raw_stream")?.value(for: "extensions")?.listItems else { continue }
            for node in extensionNodes {
                guard let value = node.scalarValue?.lowercased(), value.hasPrefix(".") else { continue }
                extensions.append(value)
            }
        }
        return Array(Set(extensions)).sorted()
    }

    /// Conservative declarative evidence from a syntactically parseable profile,
    /// independent of full schema acceptance: claimed extensions plus per-mode
    /// detect signatures in both the v1 (`modes[].detect`) and legacy
    /// (`application_modes[].detect.signatures`) shapes, plus per-mode
    /// `filename_contains_all` tokens only when `filenameTrusted` (declared
    /// schema v2). Detect evidence is complete-list only: the whole value must
    /// be a list of scalar strings with at least one non-empty survivor, so a
    /// mixed scalar/non-scalar list contributes nothing instead of lending its
    /// valid-looking members false trust.
    private static func trustworthySignatures(_ node: YAMLNode?) -> [String] {
        guard let items = node?.listItems else { return [] }
        var kept: [String] = []
        for item in items {
            guard case .scalar(let text) = item else { return [] }
            if !text.isEmpty { kept.append(text) }
        }
        return kept
    }

    /// Complete filename-token list: the whole value must be a non-empty list
    /// of non-empty scalar strings. Returns nil for a missing value and for
    /// any malformed one; scalarValue is nil for empty strings and non-scalars
    /// alike, so both are rejected by matching `.scalar` directly.
    private static func filenameTokenList(_ node: YAMLNode?) -> [String]? {
        guard let items = node?.listItems, !items.isEmpty else { return nil }
        var tokens: [String] = []
        for item in items {
            guard case .scalar(let text) = item, !text.isEmpty else { return nil }
            tokens.append(text)
        }
        return tokens
    }

    private static func lenientSelectors(_ root: YAMLNode, filenameTrusted: Bool) -> Selectors {
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
        var modeSelectors: [BrokenModeSelectors] = []
        if let modeNodes = root.value(for: "modes")?.listItems {
            for mode in modeNodes {
                let sigs = trustworthySignatures(mode.value(for: "detect"))
                var filenames: [String]? = nil
                if filenameTrusted, let filenameNode = mode.value(for: "filename_contains_all") {
                    filenames = filenameTokenList(filenameNode)
                }
                modeSelectors.append(BrokenModeSelectors(filenames: filenames, signatures: sigs))
            }
        }
        if let modeNodes = root.value(for: "application_modes")?.listItems {
            for mode in modeNodes {
                let sigs = trustworthySignatures(mode.value(for: "detect")?.value(for: "signatures"))
                modeSelectors.append(BrokenModeSelectors(filenames: nil, signatures: sigs))
            }
        }
        return Selectors(extensions: Array(Set(extensions)).sorted(), modeSelectors: modeSelectors)
    }

    private static func validate(_ root: YAMLNode, relativePath: String, sha256: String, selectors: Selectors, version: Int) -> ProfileLoadOutcome {
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
        rejectUnknown(root, allowed: ["schema_version", "id", "instrument", "formats", "modes"], scope: "")

        guard let instrumentNode = root.value(for: "instrument"), instrumentNode.mapEntries != nil else {
            fail("instrument mapping is required.")
            return ProfileLoadOutcome(profile: nil, issues: errors, extensions: extensions, modeSelectors: selectors.modeSelectors)
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
            // headerless positional `comment-tsv` layout and the explicit
            // `first-row-header` layout (first non-blank line is the header).
            let supportedKinds = version >= 2 ? ["tabular", "comment-tsv", "first-row-header"] : ["tabular"]
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
            let allowedKeys: Set<String> = kind == "tabular"
                ? ["id", "kind", "extensions", "delimiter", "encoding", "rows", "columns", "decimal"]
                : ["id", "kind", "extensions", "delimiter", "encoding", "columns", "decimal"]
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
            if kind == "comment-tsv" || kind == "first-row-header" {
                if node.value(for: "rows") != nil {
                    let reason = kind == "comment-tsv" ? "headerless positional layout" : "first row is the header by definition"
                    fail("\(field).rows is not part of kind \"\(kind)\" (\(reason)); remove the rows mapping.")
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
                // Schema v2 tabular and first-row-header columns may declare an
                // optional channel (`required: false`); schema v1 and headerless
                // layouts reject the key as unknown, unchanged.
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
            var modeAllowed: Set<String> = ["id", "format", "detect", "extract"]
            if version >= 2 { modeAllowed.insert("filename_contains_all") }
            rejectUnknown(node, allowed: modeAllowed, scope: field, skipping: ["transforms"])
            let detect: [String]
            if let detectNode = node.value(for: "detect") {
                guard let parsed = stringList(detectNode, "\(field).detect") else { continue }
                detect = parsed.filter { !$0.isEmpty }
            } else {
                detect = []
            }
            if detect.isEmpty { fail("\(field).detect must list at least one header signature string.") }
            // Schema v2 only: optional basename gate. When present it must be
            // a non-empty list of non-empty strings; v1 rejects the key above.
            var filenameTokens: [String]? = nil
            if version >= 2, let filenameNode = node.value(for: "filename_contains_all") {
                guard let tokens = filenameTokenList(filenameNode) else {
                    fail("\(field).filename_contains_all must be a non-empty list of non-empty strings.")
                    continue
                }
                filenameTokens = tokens
            }
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
            let when = ProfileWhenMatcher.whenFromLegacy(detect: detect, filenameContainsAll: filenameTokens)
            modes.append(ProfileMode(id: id, formatID: formatID, detect: detect, filenameContainsAll: filenameTokens, when: when, x: x, y: y))
        }

        guard errors.isEmpty, let instrumentID, let instrumentName else {
            return ProfileLoadOutcome(profile: nil, issues: errors.isEmpty ? ["\(relativePath): profile is incomplete."] : errors, extensions: extensions, modeSelectors: selectors.modeSelectors)
        }
        let profileID = root.value(for: "id")?.scalarValue ?? instrumentID
        let profile = InstrumentProfile(profileID: profileID, instrumentID: instrumentID, instrumentName: instrumentName,
                                        vendor: vendor, model: model, formats: formats, modes: modes,
                                        relativePath: relativePath, sha256: sha256, schemaVersion: version,
                                        profileWhen: nil)
        return ProfileLoadOutcome(profile: profile, issues: [], extensions: extensions, modeSelectors: [])
    }

    /// Declared encoding names shared with schema-v3 raw streams (Task 4
    /// resolution decodes each variant with its own declared alternatives).
    static func encoding(named name: String) -> String.Encoding? {
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

// MARK: - Profile schema v3: typed variant document

/// Errors from v3 document parse/validation/serialization. Structural faults
/// (`.invalid`) stay distinct from grammar-catalog reference faults
/// (`.unresolvedReference`) so callers can tell a malformed document from a
/// grammar-rebinding need.
public enum ProfileDocumentError: Error, LocalizedError, Equatable {
    case parseFailed(message: String)
    case invalid(reason: String)
    case unresolvedReference(reason: String)

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let message): return message
        case .invalid(let reason): return reason
        case .unresolvedReference(let reason): return reason
        }
    }
}

// MARK: - Task 1: strict editor discovery (valid v3 only)

/// One profile file the editor refuses to list: never selectable, never
/// lenient-loaded. The original file stays untouched; `reason` carries the
/// actual parse/validation failure for import errors and the excluded-count
/// diagnostic.
public struct EditorExcludedProfile: Sendable, Equatable {
    public let fileName: String
    public let reason: String

    public init(fileName: String, reason: String) {
        self.fileName = fileName
        self.reason = reason
    }
}

/// Editor-only v3 filter over already-read file texts. Runtime legacy
/// compatibility is untouched: this never parses leniently, it only keeps
/// files that strictly parse as v3 and validate against `catalog`.
public enum EditorProfileDiscovery {
    public static func classify(
        fileName: String, text: String, catalog: FilenameGrammarCatalog
    ) -> EditorExcludedProfile? {
        do {
            try ProfileDocumentV3.parse(text: text).validate(catalog: catalog)
            return nil
        } catch {
            return EditorExcludedProfile(fileName: fileName, reason: error.localizedDescription)
        }
    }

    public static func partition(
        files: [(fileName: String, text: String)], catalog: FilenameGrammarCatalog
    ) -> (valid: [String], excluded: [EditorExcludedProfile]) {
        var valid: [String] = []
        var excluded: [EditorExcludedProfile] = []
        for file in files {
            if let miss = classify(fileName: file.fileName, text: file.text, catalog: catalog) {
                excluded.append(miss)
            } else {
                valid.append(file.fileName)
            }
        }
        return (valid, excluded)
    }
}

/// Optional link to the exact legacy companion file a v3 document was
/// imported from. Catalog shadowing may only suppress that unchanged exact
/// file, never an unrelated legacy peer.
public struct ProfileLegacyOrigin: Sendable, Equatable {
    public var path: String
    public var sha256: String

    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

/// Header locator: null, `{row: positiveInt}`, `{first_nonblank: true}` or
/// `{prefix: nonemptyString}`. Coordinates are one-based physical rows.
public enum HeaderLocatorV3: Sendable, Equatable {
    case none
    case row(Int)
    case firstNonBlank
    case prefix(String)
}

public enum DataStartV3: Sendable, Equatable {
    case row(Int)
    case afterHeader
}

public struct RowLocatorsV3: Sendable, Equatable {
    public var header: HeaderLocatorV3
    public var dataStart: DataStartV3
    /// Nil when absent. An empty string is a real value: no prefix filter.
    public var dataPrefix: String?
    public var commentPrefix: String?
    public var excludedMetadata: [Int]

    public init(
        header: HeaderLocatorV3 = .none,
        dataStart: DataStartV3 = .afterHeader,
        dataPrefix: String? = nil,
        commentPrefix: String? = nil,
        excludedMetadata: [Int] = []
    ) {
        self.header = header
        self.dataStart = dataStart
        self.dataPrefix = dataPrefix
        self.commentPrefix = commentPrefix
        self.excludedMetadata = excludedMetadata
    }
}

/// Column source: stable IDs are independent of header names. Requires column
/// or header; aliases require header. `column` is a one-based physical token.
public struct ColumnSourceV3: Sendable, Equatable {
    public var column: Int?
    public var header: String?
    public var aliases: [String]

    public init(column: Int? = nil, header: String? = nil, aliases: [String] = []) {
        self.column = column
        self.header = header
        self.aliases = aliases
    }
}

public enum ColumnRoleV3: String, Sendable, Equatable {
    case channel
    case progression
    case skip
}

public enum AxisV3: String, Sendable, Equatable {
    case x
    case y
}

public enum ProgressionTypeV3: String, Sendable, Equatable {
    case index
    case time
    case custom
}

public enum ProgressionBehaviorV3: String, Sendable, Equatable {
    case continuous
    case discrete
}

public struct ColumnProgressionV3: Sendable, Equatable {
    public var type: ProgressionTypeV3
    public var name: String?
    public var behavior: ProgressionBehaviorV3?

    public init(type: ProgressionTypeV3, name: String? = nil, behavior: ProgressionBehaviorV3? = nil) {
        self.type = type
        self.name = name
        self.behavior = behavior
    }
}

public struct ProfileColumnV3: Sendable, Equatable {
    public var id: String
    public var source: ColumnSourceV3
    public var label: String
    public var quantity: String
    public var unit: String?
    public var required: Bool
    public var role: ColumnRoleV3
    public var axes: [AxisV3]
    public var progression: ColumnProgressionV3?

    public init(
        id: String,
        source: ColumnSourceV3 = ColumnSourceV3(),
        label: String = "",
        quantity: String = "",
        unit: String? = nil,
        required: Bool = true,
        role: ColumnRoleV3 = .channel,
        axes: [AxisV3] = [],
        progression: ColumnProgressionV3? = nil
    ) {
        self.id = id
        self.source = source
        self.label = label
        self.quantity = quantity
        self.unit = unit
        self.required = required
        self.role = role
        self.axes = axes
        self.progression = progression
    }
}

public struct VariantMetadataV3: Sendable, Equatable {
    public var key: String
    public var role: String
    public var row: Int?
    public var column: Int?
    public var format: String?
    public var parameterName: String?
    public var parameterRow: Int?
    public var parameterColumn: Int?

    public init(
        key: String, role: String,
        row: Int? = nil, column: Int? = nil,
        format: String? = nil,
        parameterName: String? = nil,
        parameterRow: Int? = nil, parameterColumn: Int? = nil
    ) {
        self.key = key
        self.role = role
        self.row = row
        self.column = column
        self.format = format
        self.parameterName = parameterName
        self.parameterRow = parameterRow
        self.parameterColumn = parameterColumn
    }
}

public struct DefaultPlotV3: Sendable, Equatable {
    public var x: String
    public var y: [String]
    public var progression: String?

    public init(x: String, y: [String], progression: String? = nil) {
        self.x = x
        self.y = y
        self.progression = progression
    }
}

/// Explicit compatibility selectors with legacy case-insensitive semantics.
/// Unknown selectors fail; empty lists are rejected.
public struct VariantMatchV3: Sendable, Equatable {
    public var filenameContainsAll: [String]?
    public var contentContainsAny: [String]?

    public init(filenameContainsAll: [String]? = nil, contentContainsAny: [String]? = nil) {
        self.filenameContainsAll = filenameContainsAll
        self.contentContainsAny = contentContainsAny
    }
}

/// Additive acquisition-metadata rules. `preHeaderFields` keeps ordered
/// pre-header records; `commentKeyValue` keeps ordered comment key=value
/// records throughout the stream. Repeated keys and order are preserved.
public enum MetadataCaptureRuleV3: Sendable, Equatable {
    case preHeaderFields
    case commentKeyValue(prefix: String)
}

public struct RawStreamV3: Sendable, Equatable {
    public var extensions: [String]
    public var encodings: [String]
    public var delimiter: String
    public var decimalSeparator: String
    public var rows: RowLocatorsV3
    public var columns: [ProfileColumnV3]

    public init(
        extensions: [String] = [], encodings: [String] = ["utf-8"],
        delimiter: String = ",", decimalSeparator: String = ".",
        rows: RowLocatorsV3 = RowLocatorsV3(), columns: [ProfileColumnV3] = []
    ) {
        self.extensions = extensions
        self.encodings = encodings
        self.delimiter = delimiter
        self.decimalSeparator = decimalSeparator
        self.rows = rows
        self.columns = columns
    }
}

public struct ProfileVariantV3: Sendable, Equatable {
    public var id: String
    public var name: String
    public var keyValues: [String: String]
    public var match: VariantMatchV3?
    public var rawStream: RawStreamV3
    public var metadata: [VariantMetadataV3]
    public var metadataCapture: [MetadataCaptureRuleV3]
    public var defaultPlot: DefaultPlotV3?

    public init(
        id: String, name: String,
        keyValues: [String: String] = [:],
        match: VariantMatchV3? = nil,
        rawStream: RawStreamV3 = RawStreamV3(),
        metadata: [VariantMetadataV3] = [],
        metadataCapture: [MetadataCaptureRuleV3] = [],
        defaultPlot: DefaultPlotV3? = nil
    ) {
        self.id = id
        self.name = name
        self.keyValues = keyValues
        self.match = match
        self.rawStream = rawStream
        self.metadata = metadata
        self.metadataCapture = metadataCapture
        self.defaultPlot = defaultPlot
    }
}

public struct ProfileDocumentV3: Sendable, Equatable {
    public var profileID: String
    public var profileName: String
    public var instrumentID: String
    public var instrumentName: String
    public var vendor: String?
    public var model: String?
    public var grammarID: String
    public var variantKeys: [String]
    public var variants: [ProfileVariantV3]
    public var legacyOrigin: ProfileLegacyOrigin?

    public init(
        profileID: String, profileName: String,
        instrumentID: String, instrumentName: String,
        vendor: String? = nil, model: String? = nil,
        grammarID: String, variantKeys: [String] = [],
        variants: [ProfileVariantV3] = [],
        legacyOrigin: ProfileLegacyOrigin? = nil
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.instrumentID = instrumentID
        self.instrumentName = instrumentName
        self.vendor = vendor
        self.model = model
        self.grammarID = grammarID
        self.variantKeys = variantKeys
        self.variants = variants
        self.legacyOrigin = legacyOrigin
    }

    /// Structural parse only: YAML syntax plus document shape. Catalog
    /// references are checked separately by `validate(catalog:)`.
    public static func parse(text: String) throws -> ProfileDocumentV3 {
        let root: YAMLNode
        do {
            root = try YAMLParser.parse(text, allowIndentlessSequences: false)
        } catch let error as YAMLParseError {
            throw ProfileDocumentError.parseFailed(message: "Profile YAML parse error \(error.localizedDescription)")
        }
        guard root.mapEntries != nil else {
            throw ProfileDocumentError.parseFailed(message: "The profile document must be a mapping.")
        }
        let doc = try ProfileV3Codec.decode(root)
        try doc.validate()
        return doc
    }

    /// Structural validation without any catalog.
    public func validate() throws {
        try ProfileV3Codec.validateStructure(self)
    }

    /// Structural validation plus Task 1 catalog checks: the grammar exists,
    /// every routing key is a declared field, and key fields are required.
    public func validate(catalog: FilenameGrammarCatalog) throws {
        try validate()
        try ProfileV3Codec.validateReferences(self, catalog: catalog)
    }

    /// Canonical block-mapping serialization. Validates first, so a failed
    /// save never emits a half-written document.
    public func serializedYAML() throws -> String {
        try validate()
        return ProfileV3Codec.encode(self)
    }
}

/// Editable upgrade state that is deliberately not a valid document yet.
/// Blocking diagnostics and missing fields fail `finalize`, never an early
/// save. Originals stay untouched; this draft only feeds explicit review.
public struct ProfileUpgradeDraft: Sendable, Equatable {
    public var profileID: String?
    public var profileName: String?
    public var instrumentID: String?
    public var instrumentName: String?
    public var vendor: String?
    public var model: String?
    public var grammarID: String?
    public var variantKeys: [String]
    public var variants: [ProfileVariantV3]
    public var diagnostics: [String]
    public var legacyOrigin: ProfileLegacyOrigin?

    public init(
        profileID: String? = nil, profileName: String? = nil,
        instrumentID: String? = nil, instrumentName: String? = nil,
        vendor: String? = nil, model: String? = nil,
        grammarID: String? = nil, variantKeys: [String] = [],
        variants: [ProfileVariantV3] = [],
        diagnostics: [String] = [],
        legacyOrigin: ProfileLegacyOrigin? = nil
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.instrumentID = instrumentID
        self.instrumentName = instrumentName
        self.vendor = vendor
        self.model = model
        self.grammarID = grammarID
        self.variantKeys = variantKeys
        self.variants = variants
        self.diagnostics = diagnostics
        self.legacyOrigin = legacyOrigin
    }

    /// Fails when any diagnostic or required field is unresolved; otherwise
    /// returns the fully validated document.
    public func finalize(catalog: FilenameGrammarCatalog) throws -> ProfileDocumentV3 {
        if let blocking = diagnostics.first {
            throw ProfileDocumentError.invalid(reason: blocking)
        }
        func need(_ value: String?, _ field: String) throws -> String {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProfileDocumentError.invalid(reason: "\(field) Needs definition before finalize.")
            }
            return value
        }
        let doc = ProfileDocumentV3(
            profileID: try need(profileID, "identity.id"),
            profileName: try need(profileName, "identity.name"),
            instrumentID: try need(instrumentID, "identity.instrument.id"),
            instrumentName: try need(instrumentName, "identity.instrument.name"),
            vendor: vendor, model: model,
            grammarID: try need(grammarID, "filename.grammar_id"),
            variantKeys: variantKeys,
            variants: variants,
            legacyOrigin: legacyOrigin)
        try doc.validate(catalog: catalog)
        return doc
    }

    /// Explicit review step (Task 5): records the chosen grammar, routing
    /// keys and per-variant values, dropping only the Needs-definition
    /// diagnostics those choices satisfy. Any other blocker (e.g. an
    /// unsupported-semantics diagnostic) stays until truly resolved; only
    /// calling this method counts as review, so re-applying the same choices
    /// is idempotent and navigation never resolves anything implicitly.
    public mutating func resolve(
        grammarID: String,
        variantKeys: [String],
        valuesByVariantID: [String: [String: String]]
    ) {
        let cleanGrammar = grammarID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.grammarID = cleanGrammar.isEmpty ? nil : cleanGrammar
        self.variantKeys = variantKeys
        for index in variants.indices {
            variants[index].keyValues = valuesByVariantID[variants[index].id] ?? [:]
        }
        if !cleanGrammar.isEmpty {
            diagnostics.removeAll { $0.hasPrefix(UpgradeNeedsDefinition.grammarPrefix) }
        }
        diagnostics.removeAll { $0.hasPrefix(UpgradeNeedsDefinition.keysPrefix) }
        for id in valuesByVariantID.keys {
            diagnostics.removeAll { $0.contains(UpgradeNeedsDefinition.valuesInfix(id)) }
        }
    }
}

private enum ProfileV3Codec {
    // MARK: decode (structural shape)

    static func decode(_ root: YAMLNode) throws -> ProfileDocumentV3 {
        try rejectUnknown(root, allowed: ["schema_version", "identity", "filename", "variants", "legacy_origin"], scope: "")
        guard let versionText = root.value(for: "schema_version")?.scalarValue, versionText == "3" else {
            throw ProfileDocumentError.invalid(reason: "schema_version must be 3 for a variant profile document.")
        }
        guard let identity = root.value(for: "identity"), identity.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "identity mapping is required.")
        }
        try rejectUnknown(identity, allowed: ["id", "name", "instrument"], scope: "identity")
        guard let profileID = identity.value(for: "id")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "identity.id is required.")
        }
        guard let profileName = identity.value(for: "name")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "identity.name is required.")
        }
        guard let instrument = identity.value(for: "instrument"), instrument.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "identity.instrument mapping is required.")
        }
        try rejectUnknown(instrument, allowed: ["id", "name", "vendor", "model"], scope: "identity.instrument")
        guard let instrumentID = instrument.value(for: "id")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "identity.instrument.id is required.")
        }
        guard let instrumentName = instrument.value(for: "name")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "identity.instrument.name is required.")
        }
        guard let filename = root.value(for: "filename"), filename.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "filename mapping is required.")
        }
        try rejectUnknown(filename, allowed: ["grammar_id", "variant_keys"], scope: "filename")
        guard let grammarID = filename.value(for: "grammar_id")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "filename.grammar_id is required.")
        }
        let variantKeys = try stringList(filename.value(for: "variant_keys"), "filename.variant_keys", allowEmpty: true)
        guard let variantNodes = root.value(for: "variants")?.listItems else {
            throw ProfileDocumentError.invalid(reason: "variants must be a list.")
        }
        var variants: [ProfileVariantV3] = []
        for (index, node) in variantNodes.enumerated() {
            variants.append(try decodeVariant(node, index: index))
        }
        let legacyOrigin = try decodeLegacyOrigin(root.value(for: "legacy_origin"))
        return ProfileDocumentV3(
            profileID: profileID, profileName: profileName,
            instrumentID: instrumentID, instrumentName: instrumentName,
            vendor: instrument.value(for: "vendor")?.scalarValue,
            model: instrument.value(for: "model")?.scalarValue,
            grammarID: grammarID, variantKeys: variantKeys,
            variants: variants, legacyOrigin: legacyOrigin)
    }

    static func decodeVariant(_ node: YAMLNode, index: Int) throws -> ProfileVariantV3 {
        let field = "variants[\(index)]"
        guard node.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field) must be a mapping.")
        }
        try rejectUnknown(node, allowed: ["id", "name", "key_values", "match", "raw_stream", "metadata",
                                      "metadata_capture", "default_plot"], scope: field)
        guard let id = node.value(for: "id")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(field).id is required.")
        }
        guard let name = node.value(for: "name")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(field).name is required.")
        }
        guard let keyEntries = node.value(for: "key_values")?.mapEntries else {
            throw ProfileDocumentError.invalid(reason: "\(field).key_values mapping is required.")
        }
        var keyValues: [String: String] = [:]
        for entry in keyEntries {
            guard let value = entry.value.scalarValue else {
                throw ProfileDocumentError.invalid(reason: "\(field).key_values.\(entry.key) must be a string.")
            }
            keyValues[entry.key] = value
        }
        guard let stream = node.value(for: "raw_stream"), stream.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field).raw_stream mapping is required.")
        }
        return ProfileVariantV3(
            id: id, name: name, keyValues: keyValues,
            match: try decodeMatch(node.value(for: "match"), field: field),
            rawStream: try decodeStream(stream, field: field),
            metadata: try decodeMetadata(node.value(for: "metadata"), field: field),
            metadataCapture: try decodeCapture(node.value(for: "metadata_capture"), field: field),
            defaultPlot: try decodePlot(node.value(for: "default_plot"), field: field))
    }

    static func decodeMatch(_ node: YAMLNode?, field: String) throws -> VariantMatchV3? {
        guard let node else { return nil }
        if case .scalar(let text) = node, text.isEmpty { return nil }
        guard node.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field).match must be a mapping.")
        }
        try rejectUnknown(node, allowed: ["filename_contains_all", "content_contains_any"], scope: "\(field).match")
        var match = VariantMatchV3()
        if node.value(for: "filename_contains_all") != nil {
            match.filenameContainsAll = try stringList(node.value(for: "filename_contains_all"),
                                                       "\(field).match.filename_contains_all", allowEmpty: false)
        }
        if node.value(for: "content_contains_any") != nil {
            match.contentContainsAny = try stringList(node.value(for: "content_contains_any"),
                                                      "\(field).match.content_contains_any", allowEmpty: false)
        }
        return match
    }

    static func decodeStream(_ node: YAMLNode, field: String) throws -> RawStreamV3 {
        let streamField = "\(field).raw_stream"
        try rejectUnknown(node, allowed: ["extensions", "encoding", "delimiter", "decimal_separator",
                                      "rows", "columns"], scope: streamField)
        let extensions = try stringList(node.value(for: "extensions"), "\(streamField).extensions", allowEmpty: false)
        let encodings = try stringList(node.value(for: "encoding"), "\(streamField).encoding", allowEmpty: false)
        guard let delimiter = node.value(for: "delimiter")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(streamField).delimiter is required.")
        }
        guard let decimal = node.value(for: "decimal_separator")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(streamField).decimal_separator is required.")
        }
        guard let rows = node.value(for: "rows"), rows.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(streamField).rows mapping is required.")
        }
        guard let columnNodes = node.value(for: "columns")?.listItems else {
            throw ProfileDocumentError.invalid(reason: "\(streamField).columns must be a list.")
        }
        var columns: [ProfileColumnV3] = []
        for (index, item) in columnNodes.enumerated() {
            columns.append(try decodeColumn(item, field: "\(streamField).columns[\(index)]"))
        }
        return RawStreamV3(extensions: extensions, encodings: encodings,
                           delimiter: delimiter, decimalSeparator: decimal,
                           rows: try decodeRows(rows, field: streamField),
                           columns: columns)
    }

    static func decodeRows(_ node: YAMLNode, field: String) throws -> RowLocatorsV3 {
        let rowsField = "\(field).rows"
        try rejectUnknown(node, allowed: ["header", "data_start", "data_prefix", "comment_prefix",
                                      "excluded_metadata"], scope: rowsField)
        var rows = RowLocatorsV3()
        if let header = node.value(for: "header") {
            rows.header = try decodeHeader(header, field: "\(rowsField).header")
        }
        guard let start = node.value(for: "data_start"), start.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(rowsField).data_start mapping is required.")
        }
        try rejectUnknown(start, allowed: ["row", "after_header"], scope: "\(rowsField).data_start")
        if start.value(for: "row") != nil {
            guard start.mapEntries?.count == 1 else {
                throw ProfileDocumentError.invalid(reason: "\(rowsField).data_start names one locator.")
            }
            rows.dataStart = .row(try positiveInt(start.value(for: "row"), "\(rowsField).data_start.row"))
        } else if let flag = start.value(for: "after_header") {
            guard start.mapEntries?.count == 1 else {
                throw ProfileDocumentError.invalid(reason: "\(rowsField).data_start names one locator.")
            }
            guard flag.scalarValue == "true" else {
                throw ProfileDocumentError.invalid(reason: "\(rowsField).data_start.after_header must be \"true\".")
            }
            rows.dataStart = .afterHeader
        } else {
            throw ProfileDocumentError.invalid(reason: "\(rowsField).data_start names one locator.")
        }
        if let prefix = node.value(for: "data_prefix") {
            guard case .scalar(let text) = prefix else {
                throw ProfileDocumentError.invalid(reason: "\(rowsField).data_prefix must be a string.")
            }
            rows.dataPrefix = text
        }
        if let comment = node.value(for: "comment_prefix") {
            guard let text = comment.scalarValue else {
                throw ProfileDocumentError.invalid(reason: "\(rowsField).comment_prefix must be a nonempty string.")
            }
            rows.commentPrefix = text
        }
        if let excluded = node.value(for: "excluded_metadata") {
            guard let items = excluded.listItems else {
                throw ProfileDocumentError.invalid(reason: "\(rowsField).excluded_metadata must be a list.")
            }
            rows.excludedMetadata = try items.map {
                try positiveInt($0, "\(rowsField).excluded_metadata")
            }
        }
        return rows
    }

    static func decodeHeader(_ node: YAMLNode, field: String) throws -> HeaderLocatorV3 {
        if case .scalar(let text) = node, text.isEmpty { return .none }
        guard let entries = node.mapEntries, entries.count == 1 else {
            throw ProfileDocumentError.invalid(reason: "\(field) names one locator.")
        }
        switch entries[0].key {
        case "row":
            return .row(try positiveInt(entries[0].value, "\(field).row"))
        case "first_nonblank":
            guard entries[0].value.scalarValue == "true" else {
                throw ProfileDocumentError.invalid(reason: "\(field).first_nonblank must be \"true\".")
            }
            return .firstNonBlank
        case "prefix":
            guard let text = entries[0].value.scalarValue else {
                throw ProfileDocumentError.invalid(reason: "\(field).prefix must be a nonempty string.")
            }
            return .prefix(text)
        default:
            throw ProfileDocumentError.invalid(reason: "\(field).\(entries[0].key) is not a header locator.")
        }
    }

    static func decodeColumn(_ node: YAMLNode, field: String) throws -> ProfileColumnV3 {
        guard node.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field) must be a mapping.")
        }
        try rejectUnknown(node, allowed: ["id", "source", "label", "quantity", "unit", "required",
                                      "role", "axes", "progression"], scope: field)
        guard let id = node.value(for: "id")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(field).id is required.")
        }
        guard let source = node.value(for: "source"), source.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field).source mapping is required.")
        }
        try rejectUnknown(source, allowed: ["column", "header", "aliases"], scope: "\(field).source")
        var columnSource = ColumnSourceV3()
        if source.value(for: "column") != nil {
            columnSource.column = try positiveInt(source.value(for: "column"), "\(field).source.column")
        }
        if let header = source.value(for: "header") {
            guard let text = header.scalarValue else {
                throw ProfileDocumentError.invalid(reason: "\(field).source.header must be a nonempty string.")
            }
            columnSource.header = text
        }
        if source.value(for: "aliases") != nil {
            columnSource.aliases = try stringList(source.value(for: "aliases"), "\(field).source.aliases", allowEmpty: true)
        }
        guard let label = node.value(for: "label")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(field).label is required.")
        }
        guard let quantity = node.value(for: "quantity")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(field).quantity is required.")
        }
        var column = ProfileColumnV3(id: id, source: columnSource, label: label, quantity: quantity,
                                     unit: node.value(for: "unit")?.scalarValue)
        if let required = node.value(for: "required") {
            guard required.scalarValue == "true" || required.scalarValue == "false" else {
                throw ProfileDocumentError.invalid(reason: "\(field).required must be \"true\" or \"false\".")
            }
            column.required = required.scalarValue == "true"
        }
        if let role = node.value(for: "role")?.scalarValue {
            guard let parsed = ColumnRoleV3(rawValue: role) else {
                throw ProfileDocumentError.invalid(reason: "\(field).role \"\(role)\" is not channel, progression or skip.")
            }
            column.role = parsed
        }
        if node.value(for: "axes") != nil {
            let names = try stringList(node.value(for: "axes"), "\(field).axes", allowEmpty: true)
            column.axes = try names.map {
                guard let axis = AxisV3(rawValue: $0) else {
                    throw ProfileDocumentError.invalid(reason: "\(field).axes entry \"\($0)\" is not x or y.")
                }
                return axis
            }
        }
        if let progression = node.value(for: "progression") {
            guard progression.mapEntries != nil else {
                throw ProfileDocumentError.invalid(reason: "\(field).progression must be a mapping.")
            }
            try rejectUnknown(progression, allowed: ["type", "name", "behavior"], scope: "\(field).progression")
            guard let typeText = progression.value(for: "type")?.scalarValue,
                  let type = ProgressionTypeV3(rawValue: typeText) else {
                throw ProfileDocumentError.invalid(reason: "\(field).progression.type must be index, time or custom.")
            }
            var behavior: ProgressionBehaviorV3? = nil
            if let behaviorText = progression.value(for: "behavior")?.scalarValue {
                guard let parsed = ProgressionBehaviorV3(rawValue: behaviorText) else {
                    throw ProfileDocumentError.invalid(reason: "\(field).progression.behavior must be continuous or discrete.")
                }
                behavior = parsed
            }
            column.progression = ColumnProgressionV3(type: type,
                                                     name: progression.value(for: "name")?.scalarValue,
                                                     behavior: behavior)
        }
        return column
    }

    static func decodeMetadata(_ node: YAMLNode?, field: String) throws -> [VariantMetadataV3] {
        guard let node else { return [] }
        guard let items = node.listItems else {
            throw ProfileDocumentError.invalid(reason: "\(field).metadata must be a list.")
        }
        return try items.enumerated().map { try decodeMetadataItem($1, field: "\(field).metadata[\($0)]") }
    }

    static func decodeMetadataItem(_ node: YAMLNode, field: String) throws -> VariantMetadataV3 {
        guard node.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field) must be a mapping.")
        }
        try rejectUnknown(node, allowed: ["key", "role", "source", "format", "parameter"], scope: field)
        guard let key = node.value(for: "key")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(field).key is required.")
        }
        guard let role = node.value(for: "role")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(field).role is required.")
        }
        guard let source = node.value(for: "source"), source.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field).source mapping is required.")
        }
        try rejectUnknown(source, allowed: ["row", "column"], scope: "\(field).source")
        var item = VariantMetadataV3(key: key, role: role,
                                     format: node.value(for: "format")?.scalarValue)
        if source.value(for: "row") != nil {
            item.row = try positiveInt(source.value(for: "row"), "\(field).source.row")
        }
        if source.value(for: "column") != nil {
            item.column = try positiveInt(source.value(for: "column"), "\(field).source.column")
        }
        guard item.row != nil || item.column != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field).source names a row or column.")
        }
        if let parameter = node.value(for: "parameter") {
            guard parameter.mapEntries != nil else {
                throw ProfileDocumentError.invalid(reason: "\(field).parameter must be a mapping.")
            }
            try rejectUnknown(parameter, allowed: ["name", "source"], scope: "\(field).parameter")
            guard let name = parameter.value(for: "name")?.scalarValue else {
                throw ProfileDocumentError.invalid(reason: "\(field).parameter.name is required.")
            }
            item.parameterName = name
            if let parameterSource = parameter.value(for: "source") {
                guard parameterSource.mapEntries != nil else {
                    throw ProfileDocumentError.invalid(reason: "\(field).parameter.source must be a mapping.")
                }
                try rejectUnknown(parameterSource, allowed: ["row", "column"], scope: "\(field).parameter.source")
                if parameterSource.value(for: "row") != nil {
                    item.parameterRow = try positiveInt(parameterSource.value(for: "row"), "\(field).parameter.source.row")
                }
                if parameterSource.value(for: "column") != nil {
                    item.parameterColumn = try positiveInt(parameterSource.value(for: "column"), "\(field).parameter.source.column")
                }
                guard item.parameterRow != nil || item.parameterColumn != nil else {
                    throw ProfileDocumentError.invalid(reason: "\(field).parameter.source names a row or column.")
                }
            }
        }
        return item
    }

    static func decodeCapture(_ node: YAMLNode?, field: String) throws -> [MetadataCaptureRuleV3] {
        guard let node else { return [] }
        guard let items = node.listItems else {
            throw ProfileDocumentError.invalid(reason: "\(field).metadata_capture must be a list.")
        }
        return try items.enumerated().map { (index, item) in
            let itemField = "\(field).metadata_capture[\(index)]"
            guard item.mapEntries != nil else {
                throw ProfileDocumentError.invalid(reason: "\(itemField) must be a mapping.")
            }
            try rejectUnknown(item, allowed: ["kind", "prefix"], scope: itemField)
            guard let kind = item.value(for: "kind")?.scalarValue else {
                throw ProfileDocumentError.invalid(reason: "\(itemField).kind is required.")
            }
            switch kind {
            case "pre_header_fields":
                guard item.value(for: "prefix") == nil else {
                    throw ProfileDocumentError.invalid(reason: "\(itemField) of kind pre_header_fields takes no prefix.")
                }
                return .preHeaderFields
            case "comment_key_value":
                guard let prefix = item.value(for: "prefix")?.scalarValue else {
                    throw ProfileDocumentError.invalid(reason: "\(itemField) of kind comment_key_value requires a nonempty prefix.")
                }
                return .commentKeyValue(prefix: prefix)
            default:
                throw ProfileDocumentError.invalid(reason: "\(itemField).kind \"\(kind)\" is not pre_header_fields or comment_key_value.")
            }
        }
    }

    static func decodePlot(_ node: YAMLNode?, field: String) throws -> DefaultPlotV3? {
        guard let node else { return nil }
        if case .scalar(let text) = node, text.isEmpty { return nil }
        guard node.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field).default_plot must be a mapping.")
        }
        try rejectUnknown(node, allowed: ["x", "y", "progression"], scope: "\(field).default_plot")
        guard let x = node.value(for: "x")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "\(field).default_plot.x is required.")
        }
        let y = try stringList(node.value(for: "y"), "\(field).default_plot.y", allowEmpty: false)
        return DefaultPlotV3(x: x, y: y, progression: node.value(for: "progression")?.scalarValue)
    }

    static func decodeLegacyOrigin(_ node: YAMLNode?) throws -> ProfileLegacyOrigin? {
        guard let node else { return nil }
        if case .scalar(let text) = node, text.isEmpty { return nil }
        guard node.mapEntries != nil else {
            throw ProfileDocumentError.invalid(reason: "legacy_origin must be a mapping.")
        }
        try rejectUnknown(node, allowed: ["path", "sha256"], scope: "legacy_origin")
        guard let path = node.value(for: "path")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "legacy_origin.path is required.")
        }
        guard let sha = node.value(for: "sha256")?.scalarValue else {
            throw ProfileDocumentError.invalid(reason: "legacy_origin.sha256 is required.")
        }
        return ProfileLegacyOrigin(path: path, sha256: sha)
    }

    // MARK: shared shape helpers

    static func rejectUnknown(_ node: YAMLNode?, allowed: Set<String>, scope: String) throws {
        guard let entries = node?.mapEntries else { return }
        for entry in entries where !allowed.contains(entry.key) {
            if scope.isEmpty {
                throw ProfileDocumentError.invalid(reason: "unknown key \"\(entry.key)\" is not part of schema v3.")
            }
            throw ProfileDocumentError.invalid(reason: "\(scope).\(entry.key) is not part of schema v3 (unknown key).")
        }
    }

    static func stringList(_ node: YAMLNode?, _ field: String, allowEmpty: Bool) throws -> [String] {
        guard let node else {
            if allowEmpty { return [] }
            throw ProfileDocumentError.invalid(reason: "\(field) must be a list.")
        }
        guard let items = node.listItems else {
            throw ProfileDocumentError.invalid(reason: "\(field) must be a list.")
        }
        var result: [String] = []
        for item in items {
            guard let value = item.scalarValue else {
                throw ProfileDocumentError.invalid(reason: "\(field) must contain only nonempty strings.")
            }
            result.append(value)
        }
        if !allowEmpty && result.isEmpty {
            throw ProfileDocumentError.invalid(reason: "\(field) must not be empty.")
        }
        return result
    }

    static func positiveInt(_ node: YAMLNode?, _ field: String) throws -> Int {
        guard let text = node?.scalarValue, let value = Int(text), value >= 1 else {
            throw ProfileDocumentError.invalid(reason: "\(field) must be a positive integer.")
        }
        return value
    }

    // MARK: structural validation (also covers programmatically built docs)

    static func validateStructure(_ doc: ProfileDocumentV3) throws {
        try safeID(doc.profileID, field: "identity.id")
        try nonEmpty(doc.profileName, field: "identity.name")
        try safeID(doc.instrumentID, field: "identity.instrument.id")
        try nonEmpty(doc.instrumentName, field: "identity.instrument.name")
        if let vendor = doc.vendor { try nonEmpty(vendor, field: "identity.instrument.vendor") }
        if let model = doc.model { try nonEmpty(model, field: "identity.instrument.model") }
        try idText(doc.grammarID, field: "filename.grammar_id")
        var seenKeys = Set<String>()
        for key in doc.variantKeys {
            try idText(key, field: "filename.variant_keys")
            guard seenKeys.insert(key).inserted else {
                throw ProfileDocumentError.invalid(reason: "filename.variant_keys entry \"\(key)\" is duplicated.")
            }
        }
        guard !doc.variants.isEmpty else {
            throw ProfileDocumentError.invalid(reason: "variants must contain at least one variant.")
        }
        var seenIDs = Set<String>()
        for (index, variant) in doc.variants.enumerated() {
            try validateVariant(variant, index: index, keys: doc.variantKeys, seenIDs: &seenIDs)
        }
        if let origin = doc.legacyOrigin {
            try nonEmpty(origin.path, field: "legacy_origin.path")
            try singleLine(origin.path, field: "legacy_origin.path")
            guard origin.sha256.count == 64,
                  origin.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw ProfileDocumentError.invalid(reason: "legacy_origin.sha256 must be 64 hexadecimal characters.")
            }
        }
    }

    static func validateVariant(_ variant: ProfileVariantV3, index: Int, keys: [String], seenIDs: inout Set<String>) throws {
        let field = "variants[\(index)]"
        try idText(variant.id, field: "\(field).id")
        guard seenIDs.insert(variant.id).inserted else {
            throw ProfileDocumentError.invalid(reason: "\(field).id \"\(variant.id)\" is duplicated.")
        }
        try nonEmpty(variant.name, field: "\(field).name")
        let keySet = Set(keys)
        let missing = keys.filter { variant.keyValues[$0] == nil }
        guard missing.isEmpty else {
            throw ProfileDocumentError.invalid(reason: "\(field).key_values is missing keys \(missing.map { "\"\($0)\"" }.joined(separator: ", ")).")
        }
        let extra = variant.keyValues.keys.filter { !keySet.contains($0) }.sorted()
        guard extra.isEmpty else {
            throw ProfileDocumentError.invalid(reason: "\(field).key_values has keys outside filename.variant_keys: \(extra.map { "\"\($0)\"" }.joined(separator: ", ")).")
        }
        for (key, value) in variant.keyValues {
            try nonEmpty(value, field: "\(field).key_values.\(key)")
        }
        if let match = variant.match {
            guard match.filenameContainsAll != nil || match.contentContainsAny != nil else {
                throw ProfileDocumentError.invalid(reason: "\(field).match names at least one selector.")
            }
            for list in [match.filenameContainsAll, match.contentContainsAny] {
                guard let list else { continue }
                guard !list.isEmpty else {
                    throw ProfileDocumentError.invalid(reason: "\(field).match selector lists must not be empty.")
                }
                for entry in list { try nonEmpty(entry, field: "\(field).match") }
            }
        }
        try validateStream(variant.rawStream, field: field)
        for (metaIndex, meta) in variant.metadata.enumerated() {
            try validateMetadata(meta, field: "\(field).metadata[\(metaIndex)]",
                                 excluded: variant.rawStream.rows.excludedMetadata)
        }
        for rule in variant.metadataCapture {
            if case .commentKeyValue(let prefix) = rule {
                try nonEmpty(prefix, field: "\(field).metadata_capture.prefix")
            }
        }
        if let plot = variant.defaultPlot {
            try validatePlot(plot, field: field, columns: variant.rawStream.columns)
        }
    }

    static func validateStream(_ stream: RawStreamV3, field: String) throws {
        let streamField = "\(field).raw_stream"
        guard !stream.extensions.isEmpty else {
            throw ProfileDocumentError.invalid(reason: "\(streamField).extensions must not be empty.")
        }
        for ext in stream.extensions {
            try nonEmpty(ext, field: "\(streamField).extensions")
            guard ext.hasPrefix(".") else {
                throw ProfileDocumentError.invalid(reason: "\(streamField).extensions entry \"\(ext)\" must start with \".\".")
            }
        }
        guard !stream.encodings.isEmpty else {
            throw ProfileDocumentError.invalid(reason: "\(streamField).encoding must not be empty.")
        }
        for name in stream.encodings {
            try nonEmpty(name, field: "\(streamField).encoding")
            guard knownEncoding(name) else {
                throw ProfileDocumentError.invalid(reason: "\(streamField).encoding entry \"\(name)\" is not supported; use utf-8, windows-1252, iso-8859-1, or ascii.")
            }
        }
        guard stream.delimiter.count == 1 else {
            throw ProfileDocumentError.invalid(reason: "\(streamField).delimiter must be a single character.")
        }
        try singleLine(stream.delimiter, field: "\(streamField).delimiter")
        guard stream.decimalSeparator == "." || stream.decimalSeparator == "," else {
            throw ProfileDocumentError.invalid(reason: "\(streamField).decimal_separator must be \".\" or \",\".")
        }
        if stream.delimiter == "," && stream.decimalSeparator == "," {
            throw ProfileDocumentError.invalid(reason: "\(streamField).decimal_separator \",\" conflicts with delimiter \",\".")
        }
        switch stream.rows.header {
        case .none, .firstNonBlank: break
        case .row(let value):
            guard value >= 1 else {
                throw ProfileDocumentError.invalid(reason: "\(streamField).rows.header.row must be a positive integer.")
            }
        case .prefix(let text):
            try nonEmpty(text, field: "\(streamField).rows.header.prefix")
        }
        switch stream.rows.dataStart {
        case .row(let value):
            guard value >= 1 else {
                throw ProfileDocumentError.invalid(reason: "\(streamField).rows.data_start.row must be a positive integer.")
            }
        case .afterHeader: break
        }
        if let prefix = stream.rows.dataPrefix {
            try singleLine(prefix, field: "\(streamField).rows.data_prefix")
        }
        if let comment = stream.rows.commentPrefix {
            try nonEmpty(comment, field: "\(streamField).rows.comment_prefix")
        }
        var seenRows = Set<Int>()
        for row in stream.rows.excludedMetadata {
            guard row >= 1 else {
                throw ProfileDocumentError.invalid(reason: "\(streamField).rows.excluded_metadata entries must be positive integers.")
            }
            guard seenRows.insert(row).inserted else {
                throw ProfileDocumentError.invalid(reason: "\(streamField).rows.excluded_metadata entry \(row) is duplicated.")
            }
        }
        guard !stream.columns.isEmpty else {
            throw ProfileDocumentError.invalid(reason: "\(streamField).columns must declare at least one column.")
        }
        var seenIDs = Set<String>()
        for (index, column) in stream.columns.enumerated() {
            try validateColumn(column, field: "\(streamField).columns[\(index)]", seenIDs: &seenIDs)
        }
    }

    static func validateColumn(_ column: ProfileColumnV3, field: String, seenIDs: inout Set<String>) throws {
        try idText(column.id, field: "\(field).id")
        guard seenIDs.insert(column.id).inserted else {
            throw ProfileDocumentError.invalid(reason: "\(field).id \"\(column.id)\" is duplicated.")
        }
        if let position = column.source.column {
            guard position >= 1 else {
                throw ProfileDocumentError.invalid(reason: "\(field).source.column must be a positive integer.")
            }
        }
        if let header = column.source.header {
            try nonEmpty(header, field: "\(field).source.header")
        } else if !column.source.aliases.isEmpty {
            throw ProfileDocumentError.invalid(reason: "\(field).source.aliases require a header.")
        }
        guard column.source.column != nil || column.source.header != nil else {
            throw ProfileDocumentError.invalid(reason: "\(field).source requires a column or header.")
        }
        for alias in column.source.aliases { try nonEmpty(alias, field: "\(field).source.aliases") }
        try nonEmpty(column.label, field: "\(field).label")
        try nonEmpty(column.quantity, field: "\(field).quantity")
        if let unit = column.unit { try nonEmpty(unit, field: "\(field).unit") }
        if Set(column.axes).count != column.axes.count {
            throw ProfileDocumentError.invalid(reason: "\(field).axes contains duplicated axes.")
        }
        if column.role == .skip {
            guard column.axes.isEmpty else {
                throw ProfileDocumentError.invalid(reason: "\(field) is skipped and must not declare axes.")
            }
            guard column.progression == nil else {
                throw ProfileDocumentError.invalid(reason: "\(field) is skipped and must not declare progression.")
            }
        }
        if let progression = column.progression {
            if let name = progression.name { try nonEmpty(name, field: "\(field).progression.name") }
        }
    }

    static func validateMetadata(_ meta: VariantMetadataV3, field: String, excluded: [Int]) throws {
        try nonEmpty(meta.key, field: "\(field).key")
        try nonEmpty(meta.role, field: "\(field).role")
        // Spec source.row/column is row-anchored: a column-only tag names no
        // fixed cell and fails here (at Save) instead of silently joining.
        guard let row = meta.row else {
            throw ProfileDocumentError.invalid(reason: "\(field).source.row is required; fixed metadata is row-anchored.")
        }
        guard row >= 1 else {
            throw ProfileDocumentError.invalid(reason: "\(field).source.row must be a positive integer.")
        }
        guard !excluded.contains(row) else {
            throw ProfileDocumentError.invalid(reason: "\(field).source.row \(row) is excluded metadata.")
        }
        if let column = meta.column {
            guard column >= 1 else {
                throw ProfileDocumentError.invalid(reason: "\(field).source.column must be a positive integer.")
            }
        }
        if let format = meta.format { try nonEmpty(format, field: "\(field).format") }
        if let name = meta.parameterName { try nonEmpty(name, field: "\(field).parameter.name") }
        // A linked key cell is row-anchored like any fixed cell.
        if meta.parameterRow != nil || meta.parameterColumn != nil {
            guard let row = meta.parameterRow else {
                throw ProfileDocumentError.invalid(reason: "\(field).parameter.source.row is required; fixed metadata is row-anchored.")
            }
            guard row >= 1 else {
                throw ProfileDocumentError.invalid(reason: "\(field).parameter.source.row must be a positive integer.")
            }
            guard !excluded.contains(row) else {
                throw ProfileDocumentError.invalid(reason: "\(field).parameter.source.row \(row) is excluded metadata.")
            }
        }
        if let column = meta.parameterColumn {
            guard column >= 1 else {
                throw ProfileDocumentError.invalid(reason: "\(field).parameter.source.column must be a positive integer.")
            }
        }
    }

    static func validatePlot(_ plot: DefaultPlotV3, field: String, columns: [ProfileColumnV3]) throws {
        func column(_ id: String, _ scope: String) throws -> ProfileColumnV3 {
            guard let found = columns.first(where: { $0.id == id }) else {
                throw ProfileDocumentError.invalid(reason: "\(field).default_plot.\(scope) \"\(id)\" is not a declared column.")
            }
            return found
        }
        let x = try column(plot.x, "x")
        guard x.required, x.role != .skip, x.axes.contains(.x) else {
            throw ProfileDocumentError.invalid(reason: "\(field).default_plot.x \"\(plot.x)\" must be a required nonskipped column declaring the x axis.")
        }
        guard !plot.y.isEmpty else {
            throw ProfileDocumentError.invalid(reason: "\(field).default_plot.y must name at least one column.")
        }
        for id in plot.y {
            let y = try column(id, "y")
            guard y.required, y.role != .skip, y.axes.contains(.y) else {
                throw ProfileDocumentError.invalid(reason: "\(field).default_plot.y \"\(id)\" must be a required nonskipped column declaring the y axis.")
            }
        }
        if let progressionID = plot.progression {
            let progression = try column(progressionID, "progression")
            guard progression.required, progression.role != .skip, progression.progression != nil else {
                throw ProfileDocumentError.invalid(reason: "\(field).default_plot.progression \"\(progressionID)\" must be a required nonskipped progression column.")
            }
        }
    }

    // MARK: catalog references (Task 1 grammar catalog)

    static func validateReferences(_ doc: ProfileDocumentV3, catalog: FilenameGrammarCatalog) throws {
        guard let grammar = catalog.grammars.first(where: { $0.id == doc.grammarID }) else {
            throw ProfileDocumentError.unresolvedReference(reason: "filename.grammar_id \"\(doc.grammarID)\" is not in the grammar catalog.")
        }
        let fields = Dictionary(uniqueKeysWithValues: grammar.fields.map { ($0.name, $0) })
        for key in doc.variantKeys {
            guard let field = fields[key] else {
                throw ProfileDocumentError.unresolvedReference(reason: "Routing key \"\(key)\" is not a field of grammar \"\(grammar.id)\".")
            }
            guard !field.isOptional else {
                throw ProfileDocumentError.unresolvedReference(reason: "Routing key \"\(key)\" must be a required grammar field.")
            }
        }
    }

    // MARK: scalar rules

    static func nonEmpty(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileDocumentError.invalid(reason: "\(field) must be nonempty.")
        }
        try singleLine(value, field: field)
    }

    static func idText(_ value: String, field: String) throws {
        try nonEmpty(value, field: field)
    }

    static func singleLine(_ value: String, field: String) throws {
        guard !value.contains("\n") && !value.contains("\r") else {
            throw ProfileDocumentError.invalid(reason: "\(field) must be single-line text.")
        }
    }

    /// Profile/instrument IDs become `<id>.yaml` file names: no separators,
    /// no parent-directory escapes.
    static func safeID(_ value: String, field: String) throws {
        try idText(value, field: field)
        guard !value.contains("/"), !value.contains("\\"),
              value != ".", value != ".." else {
            throw ProfileDocumentError.invalid(reason: "\(field) \"\(value)\" is not a safe profile file name.")
        }
    }

    static func knownEncoding(_ name: String) -> Bool {
        ["utf-8", "utf8", "windows-1252", "cp1252",
         "iso-8859-1", "latin-1", "latin1", "ascii", "us-ascii"].contains(name.lowercased())
    }

    // MARK: encode (canonical block mappings only)

    static func yq(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    static func encode(_ doc: ProfileDocumentV3) -> String {
        var lines: [String] = []
        lines.append("schema_version: 3")
        lines.append("identity:")
        lines.append("  id: \(yq(doc.profileID))")
        lines.append("  name: \(yq(doc.profileName))")
        lines.append("  instrument:")
        lines.append("    id: \(yq(doc.instrumentID))")
        lines.append("    name: \(yq(doc.instrumentName))")
        if let vendor = doc.vendor { lines.append("    vendor: \(yq(vendor))") }
        if let model = doc.model { lines.append("    model: \(yq(model))") }
        lines.append("filename:")
        lines.append("  grammar_id: \(yq(doc.grammarID))")
        lines.append("  variant_keys:")
        for key in doc.variantKeys { lines.append("    - \(yq(key))") }
        if let origin = doc.legacyOrigin {
            lines.append("legacy_origin:")
            lines.append("  path: \(yq(origin.path))")
            lines.append("  sha256: \(yq(origin.sha256))")
        }
        lines.append("variants:")
        for variant in doc.variants { encodeVariant(variant, into: &lines) }
        return lines.joined(separator: "\n") + "\n"
    }

    static func encodeVariant(_ variant: ProfileVariantV3, into lines: inout [String]) {
        lines.append("  - id: \(yq(variant.id))")
        lines.append("    name: \(yq(variant.name))")
        lines.append("    key_values:")
        for key in variant.keyValues.keys.sorted() {
            lines.append("      \(key): \(yq(variant.keyValues[key] ?? ""))")
        }
        if let match = variant.match {
            lines.append("    match:")
            if let filenames = match.filenameContainsAll {
                lines.append("      filename_contains_all:")
                for entry in filenames { lines.append("        - \(yq(entry))") }
            }
            if let contents = match.contentContainsAny {
                lines.append("      content_contains_any:")
                for entry in contents { lines.append("        - \(yq(entry))") }
            }
        }
        let stream = variant.rawStream
        lines.append("    raw_stream:")
        lines.append("      extensions:")
        for ext in stream.extensions { lines.append("        - \(yq(ext.lowercased()))") }
        lines.append("      encoding:")
        for name in stream.encodings { lines.append("        - \(yq(name))") }
        lines.append("      delimiter: \(yq(stream.delimiter))")
        lines.append("      decimal_separator: \(yq(stream.decimalSeparator))")
        lines.append("      rows:")
        switch stream.rows.header {
        case .none:
            lines.append("        header: null")
        case .row(let row):
            lines.append("        header:")
            lines.append("          row: \(row)")
        case .firstNonBlank:
            lines.append("        header:")
            lines.append("          first_nonblank: true")
        case .prefix(let prefix):
            lines.append("        header:")
            lines.append("          prefix: \(yq(prefix))")
        }
        switch stream.rows.dataStart {
        case .row(let row):
            lines.append("        data_start:")
            lines.append("          row: \(row)")
        case .afterHeader:
            lines.append("        data_start:")
            lines.append("          after_header: true")
        }
        if let prefix = stream.rows.dataPrefix { lines.append("        data_prefix: \(yq(prefix))") }
        if let comment = stream.rows.commentPrefix { lines.append("        comment_prefix: \(yq(comment))") }
        if stream.rows.excludedMetadata.isEmpty {
            lines.append("        excluded_metadata: []")
        } else {
            lines.append("        excluded_metadata:")
            for row in stream.rows.excludedMetadata { lines.append("          - \(row)") }
        }
        lines.append("      columns:")
        for column in stream.columns { encodeColumn(column, into: &lines) }
        if variant.metadata.isEmpty {
            lines.append("    metadata: []")
        } else {
            lines.append("    metadata:")
            for meta in variant.metadata { encodeMetadata(meta, into: &lines) }
        }
        if variant.metadataCapture.isEmpty {
            lines.append("    metadata_capture: []")
        } else {
            lines.append("    metadata_capture:")
            for rule in variant.metadataCapture {
                switch rule {
                case .preHeaderFields:
                    lines.append("      - kind: \"pre_header_fields\"")
                case .commentKeyValue(let prefix):
                    lines.append("      - kind: \"comment_key_value\"")
                    lines.append("        prefix: \(yq(prefix))")
                }
            }
        }
        if let plot = variant.defaultPlot {
            lines.append("    default_plot:")
            lines.append("      x: \(yq(plot.x))")
            lines.append("      y:")
            for id in plot.y { lines.append("        - \(yq(id))") }
            if let progression = plot.progression { lines.append("      progression: \(yq(progression))") }
        } else {
            lines.append("    default_plot: null")
        }
    }

    static func encodeColumn(_ column: ProfileColumnV3, into lines: inout [String]) {
        lines.append("        - id: \(yq(column.id))")
        lines.append("          source:")
        if let position = column.source.column { lines.append("            column: \(position)") }
        if let header = column.source.header { lines.append("            header: \(yq(header))") }
        if column.source.aliases.isEmpty {
            lines.append("            aliases: []")
        } else {
            lines.append("            aliases:")
            for alias in column.source.aliases { lines.append("              - \(yq(alias))") }
        }
        lines.append("          label: \(yq(column.label))")
        lines.append("          quantity: \(yq(column.quantity))")
        if let unit = column.unit { lines.append("          unit: \(yq(unit))") }
        lines.append("          required: \(column.required ? "true" : "false")")
        lines.append("          role: \(yq(column.role.rawValue))")
        if column.axes.isEmpty {
            lines.append("          axes: []")
        } else {
            lines.append("          axes:")
            for axis in column.axes { lines.append("            - \(yq(axis.rawValue))") }
        }
        if let progression = column.progression {
            lines.append("          progression:")
            lines.append("            type: \(yq(progression.type.rawValue))")
            if let name = progression.name { lines.append("            name: \(yq(name))") }
            if let behavior = progression.behavior { lines.append("            behavior: \(yq(behavior.rawValue))") }
        }
    }

    static func encodeMetadata(_ meta: VariantMetadataV3, into lines: inout [String]) {
        lines.append("      - key: \(yq(meta.key))")
        lines.append("        role: \(yq(meta.role))")
        lines.append("        source:")
        if let row = meta.row { lines.append("          row: \(row)") }
        if let column = meta.column { lines.append("          column: \(column)") }
        if let format = meta.format { lines.append("        format: \(yq(format))") }
        if let name = meta.parameterName {
            lines.append("        parameter:")
            lines.append("          name: \(yq(name))")
            if meta.parameterRow != nil || meta.parameterColumn != nil {
                lines.append("          source:")
                if let row = meta.parameterRow { lines.append("            row: \(row)") }
                if let column = meta.parameterColumn { lines.append("            column: \(column)") }
            }
        }
    }
}

// MARK: - Task 5: thin legacy (v1/v2) conversion adapter

/// Shared Needs-definition diagnostic shapes. The adapter emits them;
/// `ProfileUpgradeDraft.resolve` retires them on explicit review. Any other
/// diagnostic text is an unsupported-semantics blocker that no review call
/// retires implicitly.
enum UpgradeNeedsDefinition {
    static let grammarPrefix = "filename.grammar_id Needs definition"
    static let keysPrefix = "filename.variant_keys Needs definition"
    static func valuesInfix(_ variantID: String) -> String {
        "[\"\(variantID)\"].key_values Needs definition"
    }
}

/// Strict thin v1/v2 → v3 conversion adapter. It consumes an
/// already-validated `InstrumentProfile` (the strict per-file loader), never
/// the lenient first-mode workspace projection, and branches only on the
/// storage layout kind — never on instrument names. Pure: no I/O, so the
/// legacy originals stay byte-identical; callers prove that separately.
/// Every selected mode becomes one variant in a single unsaved draft with
/// `legacy_origin` set; grammar and routing values are Needs definition,
/// never guessed.
enum LegacyProfileUpgrader {
    static func draft(
        from profile: InstrumentProfile,
        modeIDs: [String]? = nil,
        legacyPath: String,
        sha256: String
    ) throws -> ProfileUpgradeDraft {
        let wanted: [ProfileMode]
        if let modeIDs {
            guard !modeIDs.isEmpty else {
                throw ProfileDocumentError.invalid(
                    reason: "Select at least one legacy mode to upgrade; nothing was selected.")
            }
            var picked: [ProfileMode] = []
            for id in modeIDs {
                guard let mode = profile.modes.first(where: { $0.id == id }) else {
                    throw ProfileDocumentError.invalid(
                        reason: "Legacy mode \"\(id)\" is not declared in \(legacyPath); choose from the declared modes.")
                }
                picked.append(mode)
            }
            wanted = picked
        } else {
            wanted = profile.modes
        }
        guard !wanted.isEmpty else {
            throw ProfileDocumentError.invalid(
                reason: "\(legacyPath) declares no modes to upgrade.")
        }
        var diagnostics = [
            "\(UpgradeNeedsDefinition.grammarPrefix): choose the grammar catalog entry matching this instrument's filenames before saving.",
            "\(UpgradeNeedsDefinition.keysPrefix): choose the required grammar fields that route sources to variants.",
        ]
        var variants: [ProfileVariantV3] = []
        for mode in wanted {
            variants.append(try variant(for: mode, profile: profile, legacyPath: legacyPath))
            diagnostics.append(
                "variants\(UpgradeNeedsDefinition.valuesInfix(mode.id)): supply a value for every routing key once keys are chosen.")
        }
        return ProfileUpgradeDraft(
            profileID: profile.profileID, profileName: profile.instrumentName,
            instrumentID: profile.instrumentID, instrumentName: profile.instrumentName,
            vendor: profile.vendor, model: profile.model,
            grammarID: nil, variantKeys: [], variants: variants,
            diagnostics: diagnostics,
            legacyOrigin: ProfileLegacyOrigin(path: legacyPath, sha256: sha256))
    }

    private static func variant(
        for mode: ProfileMode, profile: InstrumentProfile, legacyPath: String
    ) throws -> ProfileVariantV3 {
        guard let format = profile.formats.first(where: { $0.id == mode.formatID }) else {
            throw ProfileDocumentError.invalid(
                reason: "Legacy mode \"\(mode.id)\" references unknown format \"\(mode.formatID)\" in \(legacyPath).")
        }
        // ponytail: branch only on the storage layout kind, never on instrument names.
        let rows: RowLocatorsV3
        let capture: [MetadataCaptureRuleV3]
        switch format.kind {
        case "tabular":
            guard let names = format.namesPrefix, let data = format.dataPrefix else {
                throw ProfileDocumentError.invalid(
                    reason: "Legacy format \"\(format.id)\" has no row-block markers for kind \"tabular\".")
            }
            rows = RowLocatorsV3(header: .prefix(names), dataStart: .afterHeader, dataPrefix: data)
            capture = [.preHeaderFields]
        case "first-row-header":
            rows = RowLocatorsV3(header: .firstNonBlank, dataStart: .afterHeader)
            capture = []
        case "comment-tsv":
            rows = RowLocatorsV3(header: .none, dataStart: .row(1), commentPrefix: "#")
            capture = [.commentKeyValue(prefix: "#")]
        default:
            throw ProfileDocumentError.invalid(
                reason: "Legacy format \"\(format.id)\" kind \"\(format.kind)\" has no v3 mapping; resolve it explicitly.")
        }
        var columns: [ProfileColumnV3] = []
        for column in format.columns {
            var source = ColumnSourceV3()
            if let index = column.index {
                // Legacy headerless positions are 0-based; v3 is 1-based physical.
                source.column = index + 1
            } else {
                source.header = column.header
                source.aliases = column.aliases
            }
            guard source.column != nil || source.header != nil else {
                throw ProfileDocumentError.invalid(
                    reason: "Legacy column \"\(column.key)\" names no header or position.")
            }
            var axes: [AxisV3] = []
            if column.key == mode.x { axes.append(.x) }
            if mode.y.contains(column.key) { axes.append(.y) }
            columns.append(ProfileColumnV3(
                id: column.key, source: source,
                label: column.label, quantity: column.quantity,
                unit: column.unit.isEmpty ? nil : column.unit,
                required: column.required, role: .channel, axes: axes))
        }
        return ProfileVariantV3(
            id: mode.id, name: mode.id, keyValues: [:],
            match: VariantMatchV3(
                filenameContainsAll: mode.filenameContainsAll,
                contentContainsAny: mode.detect),
            rawStream: RawStreamV3(
                extensions: format.extensions, encodings: format.encodingNames,
                delimiter: String(format.delimiter),
                decimalSeparator: String(format.decimalSeparator),
                rows: rows, columns: columns),
            // ponytail: legacy declares no fixed cells and only row-anchored
            // metadata is representable, so none is emitted here.
            metadata: [],
            metadataCapture: capture,
            defaultPlot: DefaultPlotV3(x: mode.x, y: mode.y))
    }
}

// MARK: - Task 5: exact profile/variant preview sample matching

/// One bounded source read offered to the matcher. `prefixBytes` holds at
/// most the reader's 64 KiB header sample; `byteSize` is the full source
/// size, so a short prefix still resolves with prefix-deferral semantics.
public struct PreviewSampleCandidate: Sendable, Equatable {
    public var sourceID: String
    public var basename: String
    public var fileExtension: String
    public var prefixBytes: Data
    public var byteSize: Int

    public init(
        sourceID: String, basename: String, fileExtension: String,
        prefixBytes: Data, byteSize: Int
    ) {
        self.sourceID = sourceID
        self.basename = basename
        self.fileExtension = fileExtension
        self.prefixBytes = prefixBytes
        self.byteSize = byteSize
    }
}

/// Preview match outcome for the active profile AND variant. Anything but
/// `.confirmed` leaves the preview unconfirmed; callers clear stale
/// confirmations on `.noMatch`.
public enum PreviewSampleMatch: Sendable, Equatable {
    case confirmed(sourceID: String)
    case noMatch
    case ambiguous(note: String)
}

/// Pure matcher over the exact v3 resolution path: one preview-only catalog
/// holding the in-memory document (so generic/legacy candidates can never
/// claim the source) plus the live grammar. Candidates are tried in the
/// given order; the first source resolving to the selected variant wins.
public enum PreviewSampleMatcher {
    public static func match(
        candidates: [PreviewSampleCandidate],
        document: ProfileDocumentV3,
        variantID: String,
        grammar: FilenameGrammarCatalog,
        grammarSHA256: String? = nil
    ) -> PreviewSampleMatch {
        let catalog = ProfileCatalog(
            profiles: [], issues: [], brokenClaims: [],
            v3Documents: [LoadedV3Document(
                document: document, relativePath: "preview", sha256: "preview")])
        let context = V3GrammarContext(catalog: grammar, sha256: grammarSHA256, error: nil)
        var ambiguity: String? = nil
        for candidate in candidates {
            let outcome = V3Reader.resolve(
                prefix: candidate.prefixBytes, extension: candidate.fileExtension,
                basename: candidate.basename, relativePath: candidate.sourceID,
                descriptorSize: Int64(candidate.byteSize),
                catalog: catalog, grammar: context)
            switch outcome {
            case .unclaimed:
                continue
            case .matched(let match, _, _, _):
                if match.variant.id == variantID {
                    return .confirmed(sourceID: candidate.sourceID)
                }
            case .failed(let note):
                if ambiguity == nil, note.contains("Ambiguous profile match") {
                    ambiguity = note
                }
            }
        }
        if let ambiguity { return .ambiguous(note: ambiguity) }
        return .noMatch
    }
}
