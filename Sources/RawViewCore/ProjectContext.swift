import Foundation

public struct ProjectContext: Sendable {
    static let skippedRawExtensions: Set<String> = ["spe", "affm"]
    public static let supportedRawExtensions: Set<String> = ["csv", "txt", "lvm"]

    public let root: URL
    public let rawRoot: URL

    /// Project-local index database location: <root>/data/.rawview/index.db
    public var indexDatabaseURL: URL {
        root.appendingPathComponent("data/.rawview/index.db")
    }

    public static func open(_ root: URL) throws -> Self {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let raw = canonicalRoot.appendingPathComponent("data/raw", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard raw.path.hasPrefix(canonicalRoot.path + "/") else { throw ReaderError.invalidProject }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: raw.path) else { throw ReaderError.invalidProject }
        return .init(root: canonicalRoot, rawRoot: raw)
    }

    public func containsSource(_ source: URL) -> Bool {
        // Pure containment on the resolved path: readability is decided by the
        // secured open, so a missing or unreadable in-root file is never
        // mislabeled as outside data/raw.
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL
        return canonical.path.hasPrefix(rawRoot.path + "/")
    }

    /// No-follow classification of a source symlink from its link text alone:
    /// `readlink` touches only the link, and only the target's parent
    /// directory is kernel-canonicalized so containment compares in one path
    /// space. The target leaf itself is never resolved, stat-ed, opened, or
    /// read. Returns whether the link text lexically stays inside `data/raw`;
    /// an unclassifiable link counts as inside so the caller fails closed
    /// with the symlink diagnostic instead of claiming an outside path.
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

    public func discoverSources() throws -> [RawSource] {
        try walkRawSources(onVisitDirectory: nil, onVisitFile: nil, cancellable: false)
    }

    /// Cancellable off-main inventory. This is the production seam used by
    /// `RawViewModel.install`: discovery runs detached (never on the main
    /// actor), outer cancellation propagates to the worker through a
    /// cancellation handler, and the walk itself stops at incremental
    /// checkpoints. The hooks fire once per visited directory / regular file.
    public func discoverSourcesAsync(
        onVisitDirectory: (@Sendable (URL) -> Void)? = nil,
        onVisitFile: (@Sendable (URL) -> Void)? = nil
    ) async throws -> [RawSource] {
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
    ) throws -> [RawSource] {
        var discovered: [String: RawSource] = [:]
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
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: rawRoot,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else {
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
                enumerator.skipDescendants()
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
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey])
            guard let values else { continue }
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
                // A descendant project carries its own data/raw marker: prune
                // the whole subtree instead of recursing into its project data.
                var isNestedProjectData: ObjCBool = false
                let marker = canonical.appendingPathComponent("data/raw", isDirectory: true).path
                if FileManager.default.fileExists(atPath: marker, isDirectory: &isNestedProjectData),
                   isNestedProjectData.boolValue {
                    enumerator.skipDescendants()
                    continue
                }
                guard visitedDirectories.insert(canonical.path).inserted else {
                    enumerator.skipDescendants()
                    continue
                }
                try checkpoint()
                onVisitDirectory?(canonical)
            } else if values.isRegularFile == true, values.isReadable == true, let size = values.fileSize {
                onVisitFile?(canonical)
                let relativePath = String(canonical.path.dropFirst(root.path.count + 1))
                discovered[relativePath] = RawSource(relativePath: relativePath, url: canonical, byteSize: Int64(size))
                // ponytail: per-file checkpoints only every 64 files; directory
                // tops plus the lazy enumerator are the cancellation bounds.
                if cancellable {
                    filesSinceCheck += 1
                    if filesSinceCheck.isMultiple(of: 64) { try Task.checkCancellation() }
                }
            }
        }
        if let enumerationError { throw enumerationError }
        return discovered.values.sorted { $0.relativePath < $1.relativePath }
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
    /// Source-local diagnostic carrying the project-relative display path.
    func readerError(display: String) -> ReaderError {
        switch self {
        case .symlink:
            return .invalidSource("\(display): source file is a symlink or was replaced by one during open; symlinks are never followed.")
        case .missing:
            return .invalidSource("\(display): source file is missing from this project's data/raw (it may have been moved or deleted after discovery).")
        case .unreadable:
            return .invalidSource("\(display): source file exists but is not readable.")
        case .escaped(let path):
            return .sourceOutsideRaw(display.isEmpty ? path : display)
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
