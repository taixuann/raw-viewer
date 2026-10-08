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
        var enumerationFailed = false
        var enumerationDetail = ""
        guard let enumerator = FileManager.default.enumerator(
            at: project.root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in enumerationFailed = true; enumerationDetail = "\(url.path): \(error.localizedDescription)"; return false }
        ) else { return ([], ["project manifest enumeration failed before any entry could be read; overlay membership unavailable."]) }
        let canonicalRoot = SecureFile.kernelCanonical(project.root.path)
        visitedDirectories.insert(project.root.path)
        visitedDirectories.insert(canonicalRoot)
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard let values else { continue }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            let projectRelative: String?
            if canonical.path == project.root.path || canonical.path == canonicalRoot {
                projectRelative = ""
            } else {
                projectRelative = project.relativePath(of: canonical)
            }
            guard let projectRelative else {
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
                if projectRelative == "data/raw" || projectRelative == "data/.cache" {
                    enumerator.skipDescendants()
                    continue
                }
                var isNestedData: ObjCBool = false
                let marker = canonical.appendingPathComponent("data/raw", isDirectory: true).path
                if !projectRelative.isEmpty,
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
            let relativePath = projectRelative
            guard !relativePath.isEmpty else { continue }
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
                node = try parseManifestSubset(text)
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
        // A partial manifest list cannot establish membership: any enumeration
        // failure discards every collected manifest and records the failure.
        if enumerationFailed {
            let detail = enumerationDetail.isEmpty ? "" : " (\(enumerationDetail))"
            issues.append("project manifest enumeration failed\(detail); overlay membership unavailable.")
            return ([], issues)
        }
        manifests.sort { $0.relativePath < $1.relativePath }
        return (manifests, issues)
    }

    /// Study manifests may contain unrelated folded/literal top-level text
    /// that the profile YAML subset deliberately does not parse. Preserve the
    /// two membership fields and replace only those unrelated block scalars
    /// with empty scalars before parsing; their contents never affect source
    /// ownership. Unsupported syntax in `study_id` or `sources` still fails
    /// closed through `YAMLParser`.
    private static func parseManifestSubset(_ text: String) throws -> YAMLNode {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count)
        var skippingBlock = false
        var seenTopLevel: Set<String> = []
        for (offset, line) in lines.enumerated() {
            let trimmedEarly = line.trimmingCharacters(in: .whitespaces)
            if skippingBlock {
                // Tabs inside unrelated block-scalar content are content, not
                // indentation: swallow indented or blank lines without any tab
                // diagnosis. Only a non-indented line ends the skipped block.
                if trimmedEarly.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t") {
                    output.append("")
                    continue
                }
                skippingBlock = false
            }
            let leading = line.prefix { $0 == " " || $0 == "\t" }
            if leading.contains("\t") {
                throw YAMLParseError(line: offset + 1, message: "tab characters are not allowed for indentation")
            }
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard indent == 0, !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let colon = trimmed.firstIndex(of: ":") else {
                output.append(line)
                continue
            }
            let key = String(trimmed[..<colon].trimmingCharacters(in: .whitespaces))
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "study_id" || key == "sources" {
                guard seenTopLevel.insert(key).inserted else {
                    throw YAMLParseError(line: offset + 1, message: "duplicate key \"\(key)\"")
                }
            }
            if key != "study_id", key != "sources", isBlockScalarIndicator(value) {
                output.append("\(key): \"\"")
                skippingBlock = true
            } else {
                output.append(line)
            }
        }
        return try YAMLParser.parse(output.joined(separator: "\n"))
    }

    private static func isBlockScalarIndicator(_ value: String) -> Bool {
        guard let marker = value.first, marker == ">" || marker == "|" else { return false }
        let modifier = value.dropFirst().split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first?.trimmingCharacters(in: .whitespaces) ?? ""
        return modifier.allSatisfy { $0 == "+" || $0 == "-" || $0.isNumber }
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
        var members: [String] = []
        members.reserveCapacity(rawPaths.count)
        for raw in rawPaths {
            guard !raw.hasPrefix("/") else {
                issues.append("\(relativePath): source path \"\(raw)\" must not be absolute; skipped.")
                return nil
            }
            let pathExt = URL(fileURLWithPath: raw).pathExtension.lowercased()
            if !ProjectContext.supportedRawExtensions.contains(pathExt) {
                continue
            }
            let projectCandidate = project.root.appendingPathComponent(raw).standardizedFileURL
            let manifestCandidate = manifestDir.appendingPathComponent(raw).standardizedFileURL
            // Study-owned inputs commonly point to immutable data/raw files
            // through explicit project-relative symlink aliases. Membership is
            // the resolved source identity, and remains eligible only when
            // every resolution ends beneath this selected project's raw root.
            let projectResolved = projectCandidate.resolvingSymlinksInPath().standardizedFileURL
            let manifestResolved = manifestCandidate.resolvingSymlinksInPath().standardizedFileURL
            func rawMember(_ url: URL) -> String? {
                guard let relative = project.relativePath(of: url), relative.hasPrefix("data/raw/") else { return nil }
                return relative
            }
            let projectMember = rawMember(projectResolved)
            let manifestMember = rawMember(manifestResolved)
            let projectInside = projectMember != nil
            let manifestInside = manifestMember != nil
            let member: String
            if projectInside && manifestInside {
                guard projectMember == manifestMember, let projectMember else {
                    issues.append("\(relativePath): source path \"\(raw)\" is ambiguous between project-relative and manifest-relative paths inside data/raw; skipped.")
                    return nil
                }
                member = projectMember
            } else if let projectMember {
                member = projectMember
            } else if let manifestMember {
                member = manifestMember
            } else {
                issues.append("\(relativePath): source path \"\(raw)\" does not resolve inside the selected project's data/raw directory; skipped.")
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
    case partial(group: FocusedOverlayGroup)
    case blocked(reason: String)
}

/// One exclusion from a focus-anchored cohort: the source plus the
/// actionable reason it cannot share the focused plot.
public struct OverlayExclusion: Sendable, Equatable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// Focus-anchored overlay cohort: the shared manifest, the plotted paths
/// (always containing the focus), and the excluded selections with reasons.
/// The cohort never drops the focus and never picks the largest subgroup.
public struct FocusedOverlayGroup: Sendable, Equatable {
    public let manifestPath: String
    public let plottedPaths: [String]
    public let excluded: [OverlayExclusion]

    public init(manifestPath: String, plottedPaths: [String], excluded: [OverlayExclusion]) {
        self.manifestPath = manifestPath
        self.plottedPaths = plottedPaths
        self.excluded = excluded
    }
}

public enum OverlayEvaluator {
    /// Fail-closed comparison of every selected measurement together. Missing,
    /// ambiguous, or different manifest membership blocks the whole comparison;
    /// incompatible or missing X/Y quantities/units block as well. Never picks a
    /// subgroup and never omits the focused source: callers keep the focused
    /// single-source plot when blocked.
    public static func evaluate(
        measurements: [NormalizedMeasurement],
        manifests: [StudyManifest] = [],
        requireManifest: Bool? = nil
    ) -> OverlayEligibility {
        guard measurements.count >= 2 else {
            return .blocked(reason: "Select at least two sources to compare. The focused source remains shown alone.")
        }
        let shouldRequire = requireManifest ?? !manifests.isEmpty
        let shared: String
        let gate = sharedManifest(measurements: measurements, manifests: manifests)
        if let gateShared = gate.shared {
            shared = gateShared
        } else if shouldRequire {
            return .blocked(reason: gate.reason ?? "Selected sources do not share one exact manifest.")
        } else {
            shared = "Comparison"
        }
        // Quantities and exact units: every X matches, every Y matches.
        // Per-source validation reuses the shared signature helper, so the
        // blocked reasons and ordering match the focused cohort exactly.
        var xQty: String?
        var xUnit: String?
        var ySignature: [(quantity: String, unit: String)]?
        for measurement in measurements {
            let peer = xySignature(of: measurement)
            guard let signature = peer.signature else {
                return .blocked(reason: peer.reason ?? "Source \(measurement.source.path) has no plottable XY view; overlay needs declared X and Y channels in acquisition order.")
            }
            if xQty == nil { xQty = signature.xQuantity; xUnit = signature.xUnit }
            else if xQty != signature.xQuantity || xUnit != signature.xUnit {
                return .blocked(reason: "X quantity mismatch: \(measurement.source.path) channel \(measurement.view.x ?? "x") declares quantity \(signature.xQuantity)/unit \(signature.xUnit) but the comparison needs quantity \(xQty ?? "?")/unit \(xUnit ?? "?") with exact units (no conversion).")
            }
            if let expected = ySignature {
                guard signature.y.count == expected.count else {
                    return .blocked(reason: "Source \(measurement.source.path) declares \(signature.y.count) Y channels; the comparison needs the same ordered Y-channel quantity/unit layout as the other selected sources.")
                }
                for index in expected.indices where expected[index].quantity != signature.y[index].quantity
                    || expected[index].unit != signature.y[index].unit {
                    return .blocked(reason: "Y channel \(index + 1) mismatch: \(measurement.source.path) declares quantity \(signature.y[index].quantity)/unit \(signature.y[index].unit), but the comparison needs quantity \(expected[index].quantity)/unit \(expected[index].unit) in the same order.")
                }
            } else {
                ySignature = signature.y
            }
        }
        return .eligible(manifestPath: shared)
    }

    /// Focus-anchored comparison. Manifest membership stays all-or-nothing
    /// over every selected measurement: missing, ambiguous, or different
    /// manifests block the whole comparison and never infer identity. When
    /// every selected measurement shares one exact manifest but declared X/Y
    /// quantity/unit layouts differ, the plotted cohort is the focused
    /// measurement plus every other selected measurement whose complete
    /// declared X/Y signature exactly matches the focus; the rest are
    /// excluded with per-source reasons. The focus is never omitted and the
    /// largest subgroup is never chosen. A nil or unselected focus falls back
    /// to the all-or-nothing comparison.
    public static func evaluateFocused(
        measurements: [NormalizedMeasurement],
        manifests: [StudyManifest] = [],
        focusedSourceID: String?,
        requireManifest: Bool? = nil
    ) -> OverlayEligibility {
        guard measurements.count >= 2 else {
            return .blocked(reason: "Select at least two sources to compare. The focused source remains shown alone.")
        }
        guard let focusID = focusedSourceID,
              measurements.contains(where: { $0.source.path == focusID }) else {
            return evaluate(measurements: measurements, manifests: manifests, requireManifest: requireManifest)
        }
        let shouldRequire = requireManifest ?? !manifests.isEmpty
        let shared: String
        let gate = sharedManifest(measurements: measurements, manifests: manifests)
        if let gateShared = gate.shared {
            shared = gateShared
        } else if shouldRequire {
            return .blocked(reason: gate.reason ?? "Selected sources do not share one exact manifest.")
        } else {
            shared = "Comparison"
        }
        guard let focus = measurements.first(where: { $0.source.path == focusID }) else {
            return .blocked(reason: "Select at least two sources to compare. The focused source remains shown alone.")
        }
        let focusSignature = xySignature(of: focus)
        guard let focusSignature = focusSignature.signature else {
            return .blocked(reason: focusSignature.reason ?? "Source \(focusID) cannot anchor a comparison.")
        }
        var plotted = [focus.source.path]
        var excluded: [OverlayExclusion] = []
        for measurement in measurements.sorted(by: { $0.source.path < $1.source.path }) {
            guard measurement.source.path != focus.source.path else { continue }
            if let reason = mismatchReason(measurement: measurement, focusPath: focus.source.path, focusSignature: focusSignature) {
                excluded.append(OverlayExclusion(path: measurement.source.path, reason: reason))
            } else {
                plotted.append(measurement.source.path)
            }
        }
        if excluded.isEmpty {
            return .eligible(manifestPath: shared)
        }
        if plotted.count >= 2 {
            return .partial(group: FocusedOverlayGroup(
                manifestPath: shared, plottedPaths: plotted, excluded: excluded))
        }
        let details = excluded.map { "\($0.path): \($0.reason)" }.joined(separator: "\n")
        return .blocked(reason: "Only the focused source (\(focus.source.path)) is compatible with itself. Excluded \(excluded.count) source(s):\n\(details)")
    }

    /// The exact shared manifest for every measurement, or the same
    /// fail-closed membership reason `evaluate` reports.
    private static func sharedManifest(measurements: [NormalizedMeasurement], manifests: [StudyManifest]) -> (shared: String?, reason: String?) {
        var manifestForSource: [String: String] = [:]
        for measurement in measurements {
            let path = measurement.source.path
            let owners = manifests.filter { $0.members.contains(path) }.map(\.relativePath).sorted()
            if owners.isEmpty {
                return (nil, "Source \(path) is not listed in any study manifest; overlay requires one exact shared manifest for every selected source.")
            }
            if owners.count > 1 {
                return (nil, "Source \(path) is listed in \(owners.count) manifests (\(owners.joined(separator: ", "))); membership must resolve through exactly one manifest.")
            }
            manifestForSource[path] = owners[0]
        }
        let distinct = Set(manifestForSource.values).sorted()
        guard distinct.count == 1, let shared = distinct.first else {
            return (nil, "Selected sources resolve to different manifests (\(distinct.joined(separator: ", "))); overlay requires one exact shared manifest. Equal Study IDs in different files remain different.")
        }
        return (shared, nil)
    }

    /// Declared plottable X/Y signature, or the fail-closed reason the source
    /// cannot anchor or join a cohort.
    private static func xySignature(of measurement: NormalizedMeasurement) -> (signature: (xQuantity: String, xUnit: String, y: [(quantity: String, unit: String)])?, reason: String?) {
        let path = measurement.source.path
        guard measurement.view.kind == "xy",
              let xName = measurement.view.x,
              let yNames = measurement.view.y, !yNames.isEmpty,
              measurement.view.preserveOrder else {
            return (nil, "Source \(path) has no plottable XY view; overlay needs declared X and Y channels in acquisition order.")
        }
        guard let xChannel = measurement.channel(named: xName) else {
            return (nil, "Source \(path) is missing its declared X channel \(xName).")
        }
        let yChannels = yNames.compactMap { measurement.channel(named: $0) }
        guard yChannels.count == yNames.count else {
            return (nil, "Source \(path) is missing a declared Y channel.")
        }
        guard let xq = nonEmpty(xChannel.quantity) else {
            return (nil, "Source \(path) channel \(xChannel.name) is missing its declared quantity; overlay needs matching X/Y quantities.")
        }
        guard hasDeclaredUnit(xChannel.unit) else {
            return (nil, "Source \(path) channel \(xChannel.name) has a missing or unspecified unit; overlay needs exact matching units.")
        }
        var ySignature: [(quantity: String, unit: String)] = []
        ySignature.reserveCapacity(yChannels.count)
        for yChannel in yChannels {
            guard let yq = nonEmpty(yChannel.quantity) else {
                return (nil, "Source \(path) channel \(yChannel.name) is missing its declared quantity; overlay needs matching X/Y quantities.")
            }
            guard hasDeclaredUnit(yChannel.unit) else {
                return (nil, "Source \(path) channel \(yChannel.name) has a missing or unspecified unit; overlay needs exact matching units.")
            }
            ySignature.append((quantity: yq, unit: yChannel.unit))
        }
        return ((xQuantity: xq, xUnit: xChannel.unit, y: ySignature), nil)
    }

    /// Nil when the measurement exactly matches the focus signature, else the
    /// actionable per-source reason it is excluded from the focused cohort.
    private static func mismatchReason(measurement: NormalizedMeasurement, focusPath: String, focusSignature: (xQuantity: String, xUnit: String, y: [(quantity: String, unit: String)])) -> String? {
        let peer = xySignature(of: measurement)
        guard let signature = peer.signature else {
            return peer.reason
        }
        if signature.xQuantity != focusSignature.xQuantity || signature.xUnit != focusSignature.xUnit {
            let xName = measurement.view.x ?? "x"
            return "X quantity mismatch: \(measurement.source.path) channel \(xName) declares quantity \(signature.xQuantity)/unit \(signature.xUnit) but the focused source (\(focusPath)) needs quantity \(focusSignature.xQuantity)/unit \(focusSignature.xUnit) with exact units (no conversion)."
        }
        guard signature.y.count == focusSignature.y.count else {
            return "Source \(measurement.source.path) declares \(signature.y.count) Y channels; the comparison needs the same ordered Y-channel quantity/unit layout as the focused source (\(focusPath))."
        }
        for index in focusSignature.y.indices where focusSignature.y[index].quantity != signature.y[index].quantity
            || focusSignature.y[index].unit != signature.y[index].unit {
            return "Y channel \(index + 1) mismatch: \(measurement.source.path) declares quantity \(signature.y[index].quantity)/unit \(signature.y[index].unit), but the focused source (\(focusPath)) needs quantity \(focusSignature.y[index].quantity)/unit \(focusSignature.y[index].unit) in the same order."
        }
        return nil
    }

    /// Presentation-only filtering: hidden series are omitted from drawing,
    /// measurements themselves are never altered, sorted, or resampled.
    public static func visible(measurements: [NormalizedMeasurement], hidden: Set<String>) -> [NormalizedMeasurement] {
        measurements.filter { !hidden.contains($0.source.path) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        guard lowered != "unspecified" && lowered != "unknown" else { return nil }
        return value
    }

    private static func hasDeclaredUnit(_ value: String) -> Bool {
        nonEmpty(value) != nil
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
