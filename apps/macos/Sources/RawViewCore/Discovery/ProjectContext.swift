import Foundation

public struct ProjectContext: Sendable {
    static let skippedRawExtensions: Set<String> = ["spe", "affm"]
    public static let supportedRawExtensions: Set<String> = ["csv", "txt", "lvm", "dat"]

    public let root: URL
    public let rawRoot: URL
    /// Configured project-relative data root (schema-validated, normalized;
    /// "." means the project directory itself). Source identity stays
    /// project-relative; `rawRoot` is derived from this value.
    public let dataRootRelativePath: String

    /// Writable project index database location: owner-private app-local
    /// under Application Support (Decision b).
    public var indexDatabaseURL: URL {
        ProjectIndexStore.preferredDestinationURL(project: self)
    }

    /// Opens a project with an explicit configured data root. The root must be
    /// a normalized project-relative path (schema v1 rules), every configured
    /// component must be a regular directory — symlinked components are
    /// rejected, never followed — and the resolved root must be an existing
    /// readable directory contained in the project. `.` selects the project
    /// directory itself as the data root.
    public static func open(_ root: URL, dataRootRelativePath: String) throws -> Self {
        try ProjectSettingsStore.validateDataRoot(dataRootRelativePath)
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        if dataRootRelativePath != "." {
            let components = dataRootRelativePath.split(separator: "/").map(String.init)
            guard SecureFile.firstSymlinkedComponent(components, beneath: canonicalRoot.path) == nil else {
                throw ReaderError.invalidProject
            }
        }
        let raw: URL
        if dataRootRelativePath == "." {
            raw = canonicalRoot
        } else {
            raw = canonicalRoot.appendingPathComponent(dataRootRelativePath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            guard raw.path.hasPrefix(canonicalRoot.path + "/") else { throw ReaderError.invalidProject }
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: raw.path) else { throw ReaderError.invalidProject }
        return .init(root: canonicalRoot, rawRoot: raw, dataRootRelativePath: dataRootRelativePath)
    }

    /// Compatibility open: consults saved project settings first; only a
    /// proven-absent settings file falls back to the legacy data/raw default.
    /// Invalid settings throw — they are never silently recovered.
    public static func open(_ root: URL) throws -> Self {
        if let settings = try ProjectSettingsStore.load(projectRoot: root) {
            return try open(root, dataRootRelativePath: settings.dataRoot)
        }
        return try open(root, dataRootRelativePath: "data/raw")
    }

    public func containsSource(_ source: URL) -> Bool {
        // Pure containment on the resolved path: readability is decided by the
        // secured open, so a missing or unreadable in-root file is never
        // mislabeled as outside the configured data root.
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL
        return canonical.path.hasPrefix(rawRoot.path + "/")
    }

    /// No-follow classification of a source symlink from its link text alone:
    /// `readlink` touches only the link, and only the target's parent
    /// directory is kernel-canonicalized so containment compares in one path
    /// space. The target leaf itself is never resolved, stat-ed, opened, or
    /// read. Returns whether the link text lexically stays inside the
    /// configured data root; an unclassifiable link counts as inside so the
    /// caller fails closed with the symlink diagnostic instead of claiming an
    /// outside path.
    func symlinkTargetResolvesInsideRaw(source: URL, linkTarget: String) -> Bool {
        let joined = linkTarget.hasPrefix("/")
            ? URL(fileURLWithPath: linkTarget)
            : source.deletingLastPathComponent().appendingPathComponent(linkTarget)
        let standardized = joined.standardizedFileURL
        let canonicalDir = SecureFile.kernelCanonical(standardized.deletingLastPathComponent().path)
        let canonicalTarget = URL(fileURLWithPath: canonicalDir)
            .appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
        let rawRootCanonical = SecureFile.kernelCanonical(rawRoot.path)
        return [rawRoot.path, rawRootCanonical].contains { root in
            canonicalTarget.path == root || canonicalTarget.path.hasPrefix(root + "/")
        }
    }

    /// Source-local display path for diagnostics: the claimed project-relative
    /// path when the selection sits inside the project, else the file name.
    public func claimedPath(of source: URL) -> String {
        if source.path.hasPrefix(root.path + "/") {
            return String(source.path.dropFirst(root.path.count + 1))
        }
        return source.lastPathComponent
    }

    /// Project-relative path in either URL or kernel-canonical path space.
    /// Nil when outside the project.
    func relativePath(of url: URL) -> String? {
        if url.path.hasPrefix(root.path + "/") {
            return String(url.path.dropFirst(root.path.count + 1))
        }
        let kernelRoot = SecureFile.kernelCanonical(root.path)
        if url.path.hasPrefix(kernelRoot + "/") {
            return String(url.path.dropFirst(kernelRoot.count + 1))
        }
        return nil
    }

    /// Lexical claimed containment: the project-relative identity of `source`
    /// when its claimed (unresolved) path sits inside the configured data
    /// root, else nil. This never follows symlinks and never replaces the
    /// descriptor verification performed by the secure open, which
    /// independently validates the opened object.
    public func sourceRelativePath(of source: URL) -> String? {
        let claimed = source.standardizedFileURL.path
        let relative: String
        if claimed.hasPrefix(root.path + "/") {
            relative = String(claimed.dropFirst(root.path.count + 1))
        } else {
            let kernelRoot = SecureFile.kernelCanonical(root.path)
            guard claimed.hasPrefix(kernelRoot + "/") else { return nil }
            relative = String(claimed.dropFirst(kernelRoot.count + 1))
        }
        guard dataRootRelativePath != "." else { return relative }
        guard relative == dataRootRelativePath || relative.hasPrefix(dataRootRelativePath + "/") else { return nil }
        return relative
    }

    public func discoverSources() throws -> [RawSource] {
        try walkRawSources(onVisitDirectory: nil, onVisitFile: nil, cancellable: false).sources
    }

    /// Cancellable off-main source discovery (compatibility seam returning
    /// `inventory.sources`). This is the production seam used by
    /// `RawViewModel.install`: discovery runs detached (never on the main
    /// actor), outer cancellation propagates to the worker through a
    /// cancellation handler, and the walk itself stops at incremental
    /// checkpoints. The hooks fire once per visited directory / regular file.
    public func discoverSourcesAsync(
        onVisitDirectory: (@Sendable (URL) -> Void)? = nil,
        onVisitFile: (@Sendable (URL) -> Void)? = nil
    ) async throws -> [RawSource] {
        try await discoverInventoryAsync(onVisitDirectory: onVisitDirectory, onVisitFile: onVisitFile).sources
    }

    /// Cancellable off-main inventory: sources, every visited directory
    /// (including intermediate and empty ones), and typed partial-I/O issues.
    /// Cancellation throws `CancellationError`; partial enumeration/metadata
    /// failures never throw — they are returned as `InventoryIssue` values
    /// beside the accessible siblings, marking the inventory incomplete.
    public func discoverInventoryAsync(
        onVisitDirectory: (@Sendable (URL) -> Void)? = nil,
        onVisitFile: (@Sendable (URL) -> Void)? = nil
    ) async throws -> SourceInventory {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try self.walkRawSources(onVisitDirectory: onVisitDirectory, onVisitFile: onVisitFile, cancellable: true)
        }
        return try await withTaskCancellationHandler(operation: {
            try await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private func walkRawSources(
        onVisitDirectory: (@Sendable (URL) -> Void)?,
        onVisitFile: (@Sendable (URL) -> Void)?,
        cancellable: Bool
    ) throws -> SourceInventory {
        var discovered: [String: RawSource] = [:]
        var directoryPaths: [String] = []
        var issues: [InventoryIssue] = []
        var visitedDirectories = Set<String>()
        var filesSinceCheck = 0

        func checkpoint() throws {
            if cancellable { try Task.checkCancellation() }
        }

        // Incremental traversal: the enumerator yields entries lazily instead
        // of loading whole directory arrays, so cancellation lands promptly
        // even inside a single very wide directory. No resource keys are
        // prefetched: traversal decisions come from the directory read
        // itself, and per-entry metadata is requested below only for entries
        // that pass the excluded-suffix name filter.
        guard let enumerator = FileManager.default.enumerator(
            at: rawRoot,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in
                // Partial enumeration failure: record the typed issue and keep
                // enumerating, so accessible siblings stay in the inventory.
                issues.append(.enumeration(path: self.relativePath(of: url) ?? url.lastPathComponent,
                                           detail: error.localizedDescription))
                return true
            })
        else {
            throw ReaderError.invalidProject
        }
        try checkpoint()
        visitedDirectories.insert(rawRoot.path)
        onVisitDirectory?(rawRoot)
        for case let url as URL in enumerator {
            // macOS Finder metadata is not a measurement source.
            if url.lastPathComponent == ".DS_Store" { continue }
            // Excluded suffixes are decided from the claimed name alone,
            // before any per-entry metadata request or symlink
            // canonicalization: an entry named *.spe/*.affm is skipped with
            // no classification at all. The viewer never opens, parses,
            // hashes, stats, copies, or transmits those names. A directory
            // carrying such a suffix is still traversed and its children are
            // filtered individually: blind `skipDescendants()` here would
            // also over-prune supported siblings (the prefetch-less
            // enumerator stops descending directories after a skipped file),
            // so the conservative choice is zero access plus normal
            // traversal rather than a name-based subtree prune.
            if Self.skippedRawExtensions.contains(url.pathExtension.lowercased()) {
                continue
            }
            // Supported measurement extensions allowlist: only known data files (.csv, .txt, .lvm)
            // enter the inventory. Symlinked directories are handled below by destination check.
            let ext = url.pathExtension.lowercased()
            let isPotentialSymlink = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
            if !isPotentialSymlink && !Self.supportedRawExtensions.contains(ext) {
                // If it is a directory, don't skip children — directories don't have a data extension.
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    // Directories continue to traversal
                } else {
                    continue
                }
            }
            // A symlink is never followed, resolved, opened, stat-ed, hashed,
            // or read: `readlink` touches only the link itself, so even a
            // dangling link is classified without reaching its target.
            // Directory symlinks are left untraversed, while a supported-name
            // file symlink is listed lexically (claimed path, no claimed
            // target size) so inspection can report the no-follow diagnostic
            // and plotting stays blocked.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                // Never `skipDescendants()` for a symlink: the prefetch-less
                // enumerator does not descend symlinked directories by itself,
                // and calling it while the current entry is a FILE poisons the
                // next real directory's traversal (probed: the directory is
                // yielded but its children are silently dropped, losing real
                // sources). Containment of any child the enumerator might still
                // yield is enforced by the canonical-path guard below, which
                // skips descendants only while a real directory is current.
                // A symlink without a supported extension or whose canonical path is not supported
                // is not a measurement source.
                let ext = url.pathExtension.lowercased()
                if !ext.isEmpty && !Self.supportedRawExtensions.contains(ext) {
                    continue
                }
                // Lexical handling only: match the enumerator's path (which
                // may use the kernel-canonical prefix) against either root
                // form, then rebuild the claimed URL from the project root so
                // downstream diagnostics and identity use one path space.
                // The link target is never resolved, opened, or stat-ed.
                let lexical = url.standardizedFileURL
                let rawRootCanonical = SecureFile.kernelCanonical(rawRoot.path)
                guard [rawRoot.path, rawRootCanonical].contains(where: {
                    lexical.path == $0 || lexical.path.hasPrefix($0 + "/")
                }) else { continue }
                guard let relativePath = self.relativePath(of: lexical),
                      !relativePath.isEmpty, !relativePath.hasPrefix("/") else { continue }
                let claimed = root.appendingPathComponent(relativePath)
                onVisitFile?(claimed)
                discovered[relativePath] = RawSource(relativePath: relativePath, url: claimed, byteSize: 0)
                if cancellable {
                    filesSinceCheck += 1
                    if filesSinceCheck.isMultiple(of: 64) { try Task.checkCancellation() }
                }
                continue
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            } catch {
                // Per-entry metadata failure: typed issue, entry skipped, and
                // its unclassified subtree is not descended (fail closed, so no
                // child can enter the inventory without a visited parent).
                issues.append(.metadata(path: self.relativePath(of: url) ?? url.lastPathComponent,
                                        detail: error.localizedDescription))
                // Prune only when the failed entry is positively known to be a
                // directory. The entry type is exactly what the failed read
                // could not report, so an unconfirmed entry (a FILE, or one
                // whose type cannot be determined) must never be pruned:
                // `skipDescendants()` while the current entry is a FILE poisons
                // the next real directory's traversal (see the symlink branch
                // above), silently losing its sources with no issue recorded.
                var failedEntryIsDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &failedEntryIsDirectory),
                   failedEntryIsDirectory.boolValue {
                    enumerator.skipDescendants()
                }
                continue
            }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            // A supported name whose canonical path carries an excluded
            // extension stays out of the inventory (fail-closed catch for
            // symlinked ancestors).
            if Self.skippedRawExtensions.contains(canonical.pathExtension.lowercased()) { continue }
            guard canonical.path.hasPrefix(rawRoot.path + "/") else {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                // RawView viewer metadata and snapshot namespaces are excluded
                // from traversal for every configured data root (not only for
                // "."), so settings, indexes and exports never become sources.
                guard let directoryRelative = relativePath(of: canonical) else {
                    enumerator.skipDescendants()
                    continue
                }
                if ProjectSettingsStore.isViewerMetadataNamespace(directoryRelative) {
                    enumerator.skipDescendants()
                    continue
                }
                guard visitedDirectories.insert(canonical.path).inserted else {
                    enumerator.skipDescendants()
                    continue
                }
                try checkpoint()
                // Directories are inventoried directly, including intermediate
                // and empty ones; the data root itself is known from context.
                directoryPaths.append(directoryRelative)
                onVisitDirectory?(canonical)
            } else if values.isRegularFile == true, let size = values.fileSize {
                // Readability is an inspection-time property, not a discovery
                // filter: an unreadable regular file stays in the inventory so
                // the indexer reports it as a typed transient failure instead
                // of silently omitting a file that exists on disk.
                onVisitFile?(canonical)
                let relativePath = String(canonical.path.dropFirst(root.path.count + 1))
                let mtime = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
                discovered[relativePath] = RawSource(relativePath: relativePath, url: canonical, byteSize: Int64(size), mtime: mtime)
                // ponytail: per-file checkpoints only every 64 files; directory
                // tops plus the lazy enumerator are the cancellation bounds.
                if cancellable {
                    filesSinceCheck += 1
                    if filesSinceCheck.isMultiple(of: 64) { try Task.checkCancellation() }
                }
            }
        }
        return SourceInventory(
            sources: discovered.values.sorted { $0.relativePath < $1.relativePath },
            directoryPaths: directoryPaths.sorted(),
            issues: issues)
    }
}

/// Serializes folder-inventory generations so a superseded discovery can never
/// install stale sources. The viewer takes a token per discovery and installs
/// only while its token is current; reselection starts a new generation.
public actor DiscoveryGate {
    private var generation = 0
    public init() {}
    /// Starts a new generation, superseding all previous ones.
    public func begin() -> Int { generation += 1; return generation }
    /// Whether the token is still the latest generation.
    public func isCurrent(_ token: Int) -> Bool { token == generation }
}

/// Failure to pin a file open without following symlinks. Callers map these
/// to source-local diagnostics carrying the project-relative display path.
enum SecureOpenError: Error, Equatable {
    case symlink(path: String)
    case missing(path: String)
    case unreadable(path: String)
    case escaped(path: String)
}

/// Descriptor-relative, no-follow opens: the returned handle pins the exact
/// object that path checks validated, closing check-to-open races where a
/// symlink is swapped in between.
enum SecureFile {
    static func openNoFollow(_ path: String) throws -> FileHandle {
        // Non-blocking open so FIFO/special files never block inspection;
        // the fstat below then fails closed on non-regular objects.
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ENOENT, ENOTDIR: throw SecureOpenError.missing(path: path)
            case ELOOP: throw SecureOpenError.symlink(path: path)
            case EACCES, EPERM: throw SecureOpenError.unreadable(path: path)
            default: throw SecureOpenError.unreadable(path: path)
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw SecureOpenError.unreadable(path: path)
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0,
              fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw SecureOpenError.unreadable(path: path)
        }
        let verifiedFlags = fcntl(fd, F_GETFL)
        guard verifiedFlags >= 0, (verifiedFlags & O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw SecureOpenError.unreadable(path: path)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Canonical path of the already-opened object (no new lookups), so the
    /// containment check below validates and hashes/reads the same object.
    static func canonicalPath(of handle: FileHandle) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard fcntl(handle.fileDescriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Kernel-domain canonicalization (POSIX realpath). `URL`
    /// path-resolution is a no-op on some system prefixes (observed: `/var`
    /// stays unresolved while the kernel reports `/private/var`), so the
    /// opened-object check below must compare kernel-canonical forms.
    static func kernelCanonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard realpath(path, &buffer) != nil else { return path }
        return String(cString: buffer)
    }

    /// lstat walk that stops at the first symlinked component beneath `base`.
    /// Returns the offending path, or nil when every existing component is a
    /// regular entry. A component that cannot be stat-ed returns nil: it
    /// cannot be followed, and the caller's own existence/open gate fails
    /// closed on it.
    static func firstSymlinkedComponent(_ components: [String], beneath base: String) -> String? {
        var path = base
        for component in components {
            path += "/" + component
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            if (info.st_mode & S_IFMT) == S_IFLNK { return path }
        }
        return nil
    }

    /// Opens `resolvedPath` without following a final-component symlink and
    /// verifies the opened object itself still sits beneath `rootPath`.
    static func openVerified(resolvedPath: String, beneath rootPath: String) throws -> FileHandle {
        let handle = try openNoFollow(resolvedPath)
        guard let actual = canonicalPath(of: handle),
              actual == rootPath || actual.hasPrefix(rootPath + "/") ||
              actual == kernelCanonical(rootPath) || actual.hasPrefix(kernelCanonical(rootPath) + "/") else {
            try? handle.close()
            throw SecureOpenError.escaped(path: resolvedPath)
        }
        return handle
    }
}

extension SecureOpenError {
    /// Source-local diagnostic carrying the project-relative display path and
    /// the configured data root the claim must stay inside.
    func readerError(display: String, dataRoot: String) -> ReaderError {
        switch self {
        case .symlink:
            return .invalidSource("\(display): source file is a symlink or was replaced by one during open; symlinks are never followed.")
        case .missing:
            return .invalidSource("\(display): source file is missing from this project's data root (\"\(dataRoot)\") (it may have been moved or deleted after discovery).")
        case .unreadable:
            return .invalidSource("\(display): source file exists but is not readable.")
        case .escaped(let path):
            return .sourceOutsideRaw(display.isEmpty ? path : display, dataRoot: dataRoot)
        }
    }

    /// Profile-issue string carrying the project-relative display path.
    func profileIssue(display: String) -> String {
        switch self {
        case .symlink:
            return "\(display): profile is a symlink or was replaced by one during open; skipped."
        case .missing:
            return "\(display): profile disappeared before it could be read; skipped."
        case .unreadable:
            return "\(display): profile is not readable; skipped."
        case .escaped:
            return "\(display): profile resolves outside this project; skipped."
        }
    }
}
