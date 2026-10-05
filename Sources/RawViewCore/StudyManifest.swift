import Foundation

/// Exact-manifest overlay membership. A manifest is an existing project YAML
/// document with a top-level `study_id` and a `sources` list of `{path}`
/// objects. Source paths resolve project-relative or manifest-relative;
/// anything else fails closed. Manifest identity is the canonical
/// project-relative manifest path: equal Study IDs in different files remain
/// different identities.
public struct StudyManifest: Sendable, Equatable {
    public let relativePath: String
    public let studyID: String
    public let members: Set<String>

    public init(relativePath: String, studyID: String, members: Set<String>) {
        self.relativePath = relativePath
        self.studyID = studyID
        self.members = members
    }
}

public enum ManifestIndex {
    static let maximumManifestBytes = 1 << 20

    public static func load(project: ProjectContext) -> (manifests: [StudyManifest], issues: [String]) {
        var manifests: [StudyManifest] = []
        var issues: [String] = []
        var visitedDirectories = Set<String>()
        guard let enumerator = FileManager.default.enumerator(
            at: project.root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in false }
        ) else { return ([], []) }
        visitedDirectories.insert(project.root.path)
        let rawRoot = project.rawRoot.standardizedFileURL
        let cacheRoot = project.root.appendingPathComponent("data/.cache", isDirectory: true).standardizedFileURL
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard let values else { continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(project.root.path + "/") || canonical.path == project.root.path else {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                // Manifests belong to project metadata, never raw data. Prune
                // before enumerating files so .spe/.affm and other raw sources
                // receive no per-entry metadata access from this scanner.
                // The cache is derived runtime state, not manifest authority;
                // pruning it also prevents repeat opens from walking thousands
                // of cache entries.
                if canonical == rawRoot || canonical == cacheRoot {
                    enumerator.skipDescendants()
                    continue
                }
                var isNestedData: ObjCBool = false
                let marker = canonical.appendingPathComponent("data/raw", isDirectory: true).path
                if canonical.path != project.root.path,
                   FileManager.default.fileExists(atPath: marker, isDirectory: &isNestedData),
                   isNestedData.boolValue {
                    enumerator.skipDescendants()
                    continue
                }
                guard visitedDirectories.insert(canonical.path).inserted else {
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard ext == "yaml" || ext == "yml" else { continue }
            let relativePath = String(canonical.path.dropFirst(project.root.path.count + 1))
            guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { continue }
            let handle: FileHandle
            do {
                handle = try SecureFile.openVerified(resolvedPath: canonical.path, beneath: project.root.path)
            } catch let error as SecureOpenError {
                issues.append(error.profileIssue(display: relativePath))
                continue
            } catch {
                continue
            }
            let raw: Data
            do {
                raw = try handle.read(upToCount: maximumManifestBytes + 1) ?? Data()
            } catch {
                issues.append("\(relativePath): manifest is not readable; skipped.")
                continue
            }
            guard raw.count <= maximumManifestBytes else {
                issues.append("\(relativePath): manifest exceeds the 1 MiB limit; skipped.")
                continue
            }
            guard let text = String(data: raw, encoding: .utf8) else {
                // Non-UTF8 YAML cannot be a manifest; profiles report this, manifests skip silently
                // unless they look like manifests (checked after parse). Skip silently here.
                continue
            }
            let node: YAMLNode
            do {
                node = try YAMLParser.parse(text)
            } catch {
                // Malformed YAML supplies no membership: only report when it
                // declares both top-level manifest keys, otherwise unrelated
                // project metadata would flood the sidebar with warnings.
                if hasTopLevelKey("study_id", in: text) && hasTopLevelKey("sources", in: text) {
                    issues.append("\(relativePath): manifest YAML parse error \(error.localizedDescription); skipped.")
                }
                continue
            }
            if let manifest = parseManifest(node, relativePath: relativePath, manifestURL: canonical, project: project, issues: &issues) {
                manifests.append(manifest)
            }
        }
        manifests.sort { $0.relativePath < $1.relativePath }
        return (manifests, issues)
    }

    private static func hasTopLevelKey(_ key: String, in text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            guard line.first != " " && line.first != "\t" else { return false }
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate == "\(key):" || candidate.hasPrefix("\(key): ") || candidate.hasPrefix("\(key):\t")
        }
    }

    private static func parseManifest(
        _ root: YAMLNode,
        relativePath: String,
        manifestURL: URL,
        project: ProjectContext,
        issues: inout [String]
    ) -> StudyManifest? {
        let studyNode = root.value(for: "study_id")
        let sourcesNode = root.value(for: "sources")
        // Unrelated project YAML is not a manifest candidate. Requiring both
        // schema keys avoids treating ordinary study metadata as an error.
        guard let studyNode, let sourcesNode else { return nil }
        guard let studyID = studyNode.scalarValue, !studyID.isEmpty else {
            issues.append("\(relativePath): study_id is required for a study manifest; skipped.")
            return nil
        }
        guard let items = sourcesNode.listItems, !items.isEmpty else {
            issues.append("\(relativePath): sources must be a non-empty list of {path} entries; skipped.")
            return nil
        }
        var rawPaths: [String] = []
        rawPaths.reserveCapacity(items.count)
        for item in items {
            guard item.mapEntries != nil,
                  let pathValue = item.value(for: "path")?.scalarValue,
                  !pathValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues.append("\(relativePath): every sources entry must be a {path} mapping with a non-empty path; skipped.")
                return nil
            }
            rawPaths.append(pathValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let manifestDir = manifestURL.deletingLastPathComponent()
        let rawRoot = project.rawRoot.standardizedFileURL
        var members: [String] = []
        members.reserveCapacity(rawPaths.count)
        for raw in rawPaths {
            guard !raw.hasPrefix("/") else {
                issues.append("\(relativePath): source path \"\(raw)\" must not be absolute; skipped.")
                return nil
            }
            let projectCandidate = project.root.appendingPathComponent(raw).standardizedFileURL
            let manifestCandidate = manifestDir.appendingPathComponent(raw).standardizedFileURL
            let projectInside = projectCandidate.path.hasPrefix(rawRoot.path + "/")
            let manifestInside = manifestCandidate.path.hasPrefix(rawRoot.path + "/")
            let chosen: URL?
            if projectInside && manifestInside {
                guard projectCandidate.path == manifestCandidate.path else {
                    issues.append("\(relativePath): source path \"\(raw)\" is ambiguous between project-relative and manifest-relative paths inside data/raw; skipped.")
                    return nil
                }
                chosen = projectCandidate
            } else if projectInside {
                chosen = projectCandidate
            } else if manifestInside {
                chosen = manifestCandidate
            } else {
                issues.append("\(relativePath): source path \"\(raw)\" does not resolve inside the selected project's data/raw directory; skipped.")
                return nil
            }
            guard let target = chosen else {
                issues.append("\(relativePath): source path \"\(raw)\" could not be resolved; skipped.")
                return nil
            }
            let member = String(target.path.dropFirst(project.root.path.count + 1))
            guard !member.isEmpty, !member.hasPrefix("/") else {
                issues.append("\(relativePath): source path \"\(raw)\" resolves outside this project; skipped.")
                return nil
            }
            members.append(member)
        }
        // Two spellings resolving to one file is an ambiguous mapping.
        if Set(members).count != members.count {
            issues.append("\(relativePath): sources list two paths to the same file; skipped.")
            return nil
        }
        return StudyManifest(relativePath: relativePath, studyID: studyID, members: Set(members))
    }
}

public enum OverlayEligibility: Sendable, Equatable {
    case eligible(manifestPath: String)
    case blocked(reason: String)
}

public enum OverlayEvaluator {
    /// Fail-closed comparison of every selected measurement together. Missing,
    /// ambiguous, or different manifest membership blocks the whole comparison;
    /// incompatible or missing X/Y quantities/units block as well. Never picks a
    /// subgroup and never omits the focused source: callers keep the focused
    /// single-source plot when blocked.
    public static func evaluate(measurements: [NormalizedMeasurement], manifests: [StudyManifest]) -> OverlayEligibility {
        guard measurements.count >= 2 else {
            return .blocked(reason: "Select at least two sources to compare. The focused source remains shown alone.")
        }
        // Membership: exactly one manifest per source, one shared manifest total.
        var manifestForSource: [String: String] = [:]
        for measurement in measurements {
            let path = measurement.source.path
            let owners = manifests.filter { $0.members.contains(path) }.map(\.relativePath).sorted()
            if owners.isEmpty {
                return .blocked(reason: "Source \(path) is not listed in any study manifest; overlay requires one exact shared manifest for every selected source.")
            }
            if owners.count > 1 {
                return .blocked(reason: "Source \(path) is listed in \(owners.count) manifests (\(owners.joined(separator: ", "))); membership must resolve through exactly one manifest.")
            }
            manifestForSource[path] = owners[0]
        }
        let distinct = Set(manifestForSource.values).sorted()
        guard distinct.count == 1, let shared = distinct.first else {
            return .blocked(reason: "Selected sources resolve to different manifests (\(distinct.joined(separator: ", "))); overlay requires one exact shared manifest. Equal Study IDs in different files remain different.")
        }
        // Quantities and exact units: every X matches, every Y matches.
        var xQty: String?
        var xUnit: String?
        var ySignature: [(quantity: String, unit: String)]?
        for measurement in measurements {
            guard measurement.view.kind == "xy",
                  let xName = measurement.view.x,
                  let yNames = measurement.view.y, !yNames.isEmpty,
                  measurement.view.preserveOrder else {
                return .blocked(reason: "Source \(measurement.source.path) has no plottable XY view; overlay needs declared X and Y channels in acquisition order.")
            }
            guard let xChannel = measurement.channel(named: xName) else {
                return .blocked(reason: "Source \(measurement.source.path) is missing its declared X channel \(xName).")
            }
            let yChannels = yNames.compactMap { measurement.channel(named: $0) }
            guard yChannels.count == yNames.count else {
                return .blocked(reason: "Source \(measurement.source.path) is missing a declared Y channel.")
            }
            guard let xq = nonEmpty(xChannel.quantity) else {
                return .blocked(reason: "Source \(measurement.source.path) channel \(xChannel.name) is missing its declared quantity; overlay needs matching X/Y quantities.")
            }
            guard hasDeclaredUnit(xChannel.unit) else {
                return .blocked(reason: "Source \(measurement.source.path) channel \(xChannel.name) has a missing or unspecified unit; overlay needs exact matching units.")
            }
            if xQty == nil { xQty = xq; xUnit = xChannel.unit }
            else if xQty != xq || xUnit != xChannel.unit {
                return .blocked(reason: "X quantity mismatch: \(measurement.source.path) channel \(xChannel.name) declares quantity \(xq)/unit \(xChannel.unit) but the comparison needs quantity \(xQty ?? "?")/unit \(xUnit ?? "?") with exact units (no conversion).")
            }
            var currentYSignature: [(quantity: String, unit: String)] = []
            currentYSignature.reserveCapacity(yChannels.count)
            for yChannel in yChannels {
                guard let yq = nonEmpty(yChannel.quantity) else {
                    return .blocked(reason: "Source \(measurement.source.path) channel \(yChannel.name) is missing its declared quantity; overlay needs matching X/Y quantities.")
                }
                guard hasDeclaredUnit(yChannel.unit) else {
                    return .blocked(reason: "Source \(measurement.source.path) channel \(yChannel.name) has a missing or unspecified unit; overlay needs exact matching units.")
                }
                currentYSignature.append((quantity: yq, unit: yChannel.unit))
            }
            if let expected = ySignature {
                guard currentYSignature.count == expected.count else {
                    return .blocked(reason: "Source \(measurement.source.path) declares \(currentYSignature.count) Y channels; the comparison needs the same ordered Y-channel quantity/unit layout as the other selected sources.")
                }
                for index in expected.indices where expected[index].quantity != currentYSignature[index].quantity
                    || expected[index].unit != currentYSignature[index].unit {
                    return .blocked(reason: "Y channel \(index + 1) mismatch: \(measurement.source.path) declares quantity \(currentYSignature[index].quantity)/unit \(currentYSignature[index].unit), but the comparison needs quantity \(expected[index].quantity)/unit \(expected[index].unit) in the same order.")
                }
            } else {
                ySignature = currentYSignature
            }
        }
        return .eligible(manifestPath: shared)
    }

    /// Presentation-only filtering: hidden series are omitted from drawing,
    /// measurements themselves are never altered, sorted, or resampled.
    public static func visible(measurements: [NormalizedMeasurement], hidden: Set<String>) -> [NormalizedMeasurement] {
        measurements.filter { !hidden.contains($0.source.path) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func hasDeclaredUnit(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && normalized != "unspecified" && normalized != "unknown"
    }
}

public enum OverlaySelection {
    /// Deterministic focused source: keep the current focus while it stays
    /// selected, otherwise take the sorted first selection.
    public static func focused(selected: Set<String>, current: String?) -> String? {
        if let current, selected.contains(current) { return current }
        return selected.sorted().first
    }
}
