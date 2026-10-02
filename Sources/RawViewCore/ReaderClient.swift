import CryptoKit
import Foundation

public enum ReaderClientError: Error, LocalizedError {
    case untrusted
    case invalidProject
    case sourceOutsideRaw
    case missingPython
    case sourceChanged
    case duplicateSourceIdentity
    case invalidReaderResponse
    case cancelled
    case readerTimedOut
    case readerOutputTooLarge
    case readerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .untrusted: "Review the project reader again; it changed after approval."
        case .invalidProject: "Choose a project containing a readable data/raw directory."
        case .sourceOutsideRaw: "The selected source resolves outside this project's data/raw folder."
        case .missingPython: "No local Python 3 runtime was found."
        case .sourceChanged: "The selected source changed while it was being parsed."
        case .duplicateSourceIdentity: "Multiple source entries share this identity; inspection was skipped for all of them."
        case .invalidReaderResponse: "The reader response did not identify the selected source and unchanged source hash."
        case .cancelled: "Inspection was cancelled."
        case .readerTimedOut: "The project reader exceeded the five-minute time limit."
        case .readerOutputTooLarge: "The project reader exceeded the 32 MiB response limit."
        case .readerFailed(let message): message
        }
    }
}

public struct ProjectContext: Sendable {
    public let root: URL
    public let rawRoot: URL
    public let reader: URL?

    public static func open(_ root: URL) throws -> Self {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let raw = canonicalRoot.appendingPathComponent("data/raw", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard raw.path.hasPrefix(canonicalRoot.path + "/") else { throw ReaderClientError.invalidProject }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: raw.path) else { throw ReaderClientError.invalidProject }
        let readerCandidate = canonicalRoot.appendingPathComponent("data/instruments/reader.py")
        return .init(root: canonicalRoot, rawRoot: raw, reader: readerCandidate)
    }

    public func containsSource(_ source: URL) -> Bool {
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL
        return canonical.path.hasPrefix(rawRoot.path + "/") && FileManager.default.isReadableFile(atPath: canonical.path)
    }

    public func discoverSources() throws -> [RawSource] {
        var discovered: [String: RawSource] = [:]
        var visitedDirectories = Set<String>()

        func visit(_ directory: URL) throws {
            let canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalDirectory.path == rawRoot.path || canonicalDirectory.path.hasPrefix(rawRoot.path + "/") else { return }
            guard visitedDirectories.insert(canonicalDirectory.path).inserted else { return }
            for entry in try FileManager.default.contentsOfDirectory(at: canonicalDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey]) {
                let canonical = entry.resolvingSymlinksInPath().standardizedFileURL
                guard canonical.path.hasPrefix(rawRoot.path + "/") else { continue }
                let values = try? canonical.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey])
                guard let values else { continue }
                if values.isDirectory == true {
                    try visit(canonical)
                } else if values.isRegularFile == true, values.isReadable == true, let size = values.fileSize {
                    let relativePath = String(canonical.path.dropFirst(root.path.count + 1))
                    discovered[relativePath] = RawSource(relativePath: relativePath, url: canonical, byteSize: Int64(size))
                }
            }
        }

        try visit(rawRoot)
        return discovered.values.sorted { $0.relativePath < $1.relativePath }
    }

    fileprivate func validatedReader() -> URL? {
        guard let reader else { return nil }
        let instrumentsRoot = root.appendingPathComponent("data/instruments", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let canonicalReader = reader.resolvingSymlinksInPath().standardizedFileURL
        guard instrumentsRoot.path.hasPrefix(root.path + "/"),
              canonicalReader.path.hasPrefix(instrumentsRoot.path + "/"),
              FileManager.default.isReadableFile(atPath: canonicalReader.path),
              let values = try? canonicalReader.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return canonicalReader
    }
}

public struct ReaderApproval: Codable, Sendable, Equatable {
    public let projectPath: String
    public let readerPath: String
    public let readerSHA256: String

    public static func issue(afterUserReviewOf project: ProjectContext) -> Self? {
        guard let reader = project.validatedReader(), let hash = try? ReaderClient.fileSHA256(reader) else { return nil }
        return Self(projectPath: project.root.path, readerPath: reader.path, readerSHA256: hash)
    }

    public func isCurrent(for project: ProjectContext) -> Bool {
        guard projectPath == project.root.path,
              let reader = project.validatedReader(), reader.path == readerPath,
              let hash = try? ReaderClient.fileSHA256(reader) else { return false }
        return hash == readerSHA256
    }
}

public struct ReaderLoadResult: Sendable {
    public let measurement: NormalizedMeasurement
    public let readerSHA256: String
}

final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func start(_ value: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        process = value
        do { try value.run() }
        catch { process = nil; throw error }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = process; lock.unlock()
        if let value, value.isRunning { value.terminate() }
    }
    func timeOut(_ value: Process) {
        lock.lock()
        guard process === value, value.isRunning else { lock.unlock(); return }
        timedOut = true
        lock.unlock()
        value.terminate()
    }
    func didTimeOut() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return timedOut
    }
}

public enum ReaderClient {
    public static func inspectMany(_ sources: [RawSource], project: ProjectContext, approval: ReaderApproval,
                                   onProgress: (@Sendable ([SourceInspectionResult], Int) async -> Void)? = nil) async -> [SourceInspectionResult] {
        guard approval.isCurrent(for: project) else {
            let results = sources.map { SourceInspectionResult(source: $0, inspection: nil, error: ReaderClientError.untrusted.localizedDescription) }
            await onProgress?(results, sources.count)
            return results
        }
        let counts = Dictionary(grouping: sources, by: \.relativePath).mapValues(\.count)
        let duplicatePaths = Set(counts.filter { $0.value > 1 }.keys)
        let uniqueSources = sources.filter { !duplicatePaths.contains($0.relativePath) }
        let safeSources = uniqueSources.filter { source in
            guard project.containsSource(source.url) else { return false }
            let path = source.url.resolvingSymlinksInPath().standardizedFileURL.path
            return String(path.dropFirst(project.root.path.count + 1)) == source.relativePath
        }
        let safePaths = Set(safeSources.map(\.relativePath))
        var inspected: [String: SourceInspection] = [:]
        var errors = Dictionary(uniqueKeysWithValues: duplicatePaths.map {
            ($0, ReaderClientError.duplicateSourceIdentity.localizedDescription)
        })
        for source in uniqueSources where !safePaths.contains(source.relativePath) {
            errors[source.relativePath] = ReaderClientError.sourceOutsideRaw.localizedDescription
        }

        let initiallyCompleted = sources.filter { !safePaths.contains($0.relativePath) }
        if !initiallyCompleted.isEmpty {
            await onProgress?(initiallyCompleted.map { source in
                .init(source: source, inspection: nil, error: errors[source.relativePath] ?? ReaderClientError.duplicateSourceIdentity.localizedDescription)
            }, initiallyCompleted.count)
        }

        let batches = InspectionBatch.chunks(safeSources)
        var completed = initiallyCompleted.count
        for (index, batch) in batches.enumerated() {
            if Task.isCancelled {
                for pending in batches[index...].flatMap({ $0 }) { errors[pending.relativePath] = ReaderClientError.cancelled.localizedDescription }
                completed = sources.count
                let cancelled = batches[index...].flatMap { $0 }.map { source in
                    SourceInspectionResult(source: source, inspection: nil, error: errors[source.relativePath])
                }
                await onProgress?(cancelled, completed)
                break
            }
            do {
                guard approval.isCurrent(for: project), let reader = project.validatedReader() else { throw ReaderClientError.untrusted }
                let response = try await runInspection(batch, reader: reader, project: project, approvedHash: approval.readerSHA256)
                let expected = Set(batch.map(\.relativePath))
                for value in response where expected.contains(value.source) {
                    guard inspected[value.source] == nil, errors[value.source] == nil else {
                        inspected[value.source] = nil
                        errors[value.source] = ReaderClientError.invalidReaderResponse.localizedDescription
                        continue
                    }
                    if let error = value.error, !error.isEmpty { errors[value.source] = String(error.prefix(4096)) }
                    else if let inspection = value.inspection { inspected[value.source] = inspection }
                    else { errors[value.source] = ReaderClientError.invalidReaderResponse.localizedDescription }
                }
                for source in batch where inspected[source.relativePath] == nil && errors[source.relativePath] == nil {
                    errors[source.relativePath] = ReaderClientError.invalidReaderResponse.localizedDescription
                }
                guard approval.isCurrent(for: project) else { throw ReaderClientError.untrusted }
            } catch {
                for source in batch { inspected[source.relativePath] = nil; errors[source.relativePath] = error.localizedDescription }
                if Task.isCancelled {
                    for source in batch { errors[source.relativePath] = ReaderClientError.cancelled.localizedDescription }
                    for pending in batches.dropFirst(index + 1).flatMap({ $0 }) { errors[pending.relativePath] = ReaderClientError.cancelled.localizedDescription }
                    completed = sources.count
                    let cancelled = batches[index...].flatMap { $0 }.map { source in
                        SourceInspectionResult(source: source, inspection: nil, error: errors[source.relativePath])
                    }
                    await onProgress?(cancelled, completed)
                    break
                }
            }
            completed += batch.count
            await onProgress?(batch.map { source in
                .init(source: source, inspection: inspected[source.relativePath], error: errors[source.relativePath])
            }, completed)
        }
        return sources.map { source in
            .init(source: source, inspection: inspected[source.relativePath], error: errors[source.relativePath])
        }
    }

    private static func runInspection(_ sources: [RawSource], reader: URL, project: ProjectContext, approvedHash: String) async throws -> [InspectionResponseRow] {
        let runner = RunningProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                guard let currentReader = project.validatedReader(), currentReader.path == reader.path else { throw ReaderClientError.untrusted }
                let expectedHash = try fileSHA256(reader)
                guard expectedHash == approvedHash else { throw ReaderClientError.untrusted }
                let process = Process()
                let output = Pipe(), diagnostics = Pipe(), input = Pipe()
                let python = pythonExecutable()
                if let python {
                    process.executableURL = python
                    process.arguments = [reader.path, "inspect-many", "--paths-json"]
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["python3", reader.path, "inspect-many", "--paths-json"]
                }
                process.currentDirectoryURL = project.root
                process.standardInput = input; process.standardOutput = output; process.standardError = diagnostics
                var environment = ProcessInfo.processInfo.environment
                try configureReaderEnvironment(&environment, pythonPath: python?.path)
                process.environment = environment
                let paths = sources.map(\.relativePath)
                let payload = try JSONSerialization.data(withJSONObject: paths)
                try Task.checkCancellation()
                guard let launchReader = project.validatedReader(), launchReader.path == reader.path,
                      try fileSHA256(launchReader) == expectedHash else { throw ReaderClientError.untrusted }
                do { try runner.start(process) } catch is CancellationError { throw CancellationError() }
                catch { throw ReaderClientError.readerFailed(error.localizedDescription) }
                let timeout = DispatchWorkItem { runner.timeOut(process) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
                let stdoutTask = Task.detached { readOutput(output.fileHandleForReading, limit: 32 * 1024 * 1024) { process.terminate() } }
                let stderrTask = Task.detached { readDiagnosticTail(diagnostics.fileHandleForReading, limit: 4096) }
                let stdinTask = Task.detached {
                    try input.fileHandleForWriting.write(contentsOf: payload)
                    try input.fileHandleForWriting.close()
                }
                process.waitUntilExit(); timeout.cancel()
                let data = await stdoutTask.value, stderr = await stderrTask.value
                do { try await stdinTask.value } catch { if process.terminationStatus == 0 { throw ReaderClientError.readerFailed(error.localizedDescription) } }
                if runner.didTimeOut() { throw ReaderClientError.readerTimedOut }
                if data.exceededLimit { throw ReaderClientError.readerOutputTooLarge }
                if process.terminationStatus != 0 {
                    let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw ReaderClientError.readerFailed(message.isEmpty ? "Reader exited with status \(process.terminationStatus)." : message)
                }
                try Task.checkCancellation()
                guard let finalReader = project.validatedReader(), finalReader.path == reader.path,
                      try fileSHA256(finalReader) == expectedHash else { throw ReaderClientError.untrusted }
                return try InspectionEnvelope.decodeRows(data.bytes)
            }.value
        } onCancel: { runner.cancel() }
    }

    public static func load(_ source: URL, project: ProjectContext, approval: ReaderApproval) async throws -> ReaderLoadResult {
        guard let reader = project.validatedReader() else { throw ReaderClientError.untrusted }
        guard approval.projectPath == project.root.path,
              approval.readerPath == reader.path,
              (try? fileSHA256(reader)) == approval.readerSHA256 else { throw ReaderClientError.untrusted }
        guard project.containsSource(source) else { throw ReaderClientError.sourceOutsideRaw }
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let expectedPath = String(canonicalSource.path.dropFirst(project.root.path.count + 1))
        let runner = RunningProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let beforeHash = try fileSHA256(canonicalSource)
                guard let readerBeforeLaunch = project.validatedReader(),
                      readerBeforeLaunch.path == approval.readerPath else { throw ReaderClientError.untrusted }
                let readerHashBefore = try fileSHA256(readerBeforeLaunch)
                guard readerHashBefore == approval.readerSHA256 else { throw ReaderClientError.untrusted }
                let process = Process()
                let output = Pipe()
                let diagnostics = Pipe()
                let python = pythonExecutable()
                if let python {
                    process.executableURL = python
                    process.arguments = [readerBeforeLaunch.path, "load", source.resolvingSymlinksInPath().path]
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["python3", readerBeforeLaunch.path, "load", source.resolvingSymlinksInPath().path]
                }
                process.currentDirectoryURL = project.root
                process.standardOutput = output
                process.standardError = diagnostics
                var environment = ProcessInfo.processInfo.environment
                try configureReaderEnvironment(&environment, pythonPath: python?.path)
                process.environment = environment
                try Task.checkCancellation()
                guard let launchReader = project.validatedReader(),
                      launchReader.path == approval.readerPath,
                      (try? fileSHA256(launchReader)) == approval.readerSHA256 else { throw ReaderClientError.untrusted }
                if process.executableURL?.path == "/usr/bin/env" {
                    process.arguments = ["python3", launchReader.path, "load", source.resolvingSymlinksInPath().path]
                } else {
                    process.arguments = [launchReader.path, "load", source.resolvingSymlinksInPath().path]
                }
                do { try runner.start(process) } catch is CancellationError { throw CancellationError() }
                catch { throw ReaderClientError.readerFailed(error.localizedDescription) }
                let timeout = DispatchWorkItem { runner.timeOut(process) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeout)
                let stdoutTask = Task.detached { readOutput(output.fileHandleForReading, limit: 32 * 1024 * 1024) { process.terminate() } }
                let stderrTask = Task.detached { readDiagnosticTail(diagnostics.fileHandleForReading, limit: 4096) }
                process.waitUntilExit()
                timeout.cancel()
                let data = await stdoutTask.value
                let stderr = await stderrTask.value
                if runner.didTimeOut() { throw ReaderClientError.readerTimedOut }
                if data.exceededLimit { throw ReaderClientError.readerOutputTooLarge }
                if process.terminationStatus != 0 {
                    let message = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let fallback = String(decoding: data.bytes.suffix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    throw ReaderClientError.readerFailed(message.isEmpty ? fallback : message)
                }
                try Task.checkCancellation()
                let measurement = try NormalizedMeasurement.decode(data.bytes)
                let afterHash = try fileSHA256(canonicalSource)
                guard beforeHash == afterHash else { throw ReaderClientError.sourceChanged }
                guard let readerAfter = project.validatedReader(), readerAfter.path == approval.readerPath else {
                    throw ReaderClientError.untrusted
                }
                let readerHashAfter = try fileSHA256(readerAfter)
                guard readerHashBefore == readerHashAfter else { throw ReaderClientError.untrusted }
                guard measurement.source.path == expectedPath, measurement.source.sha256 == beforeHash else {
                    throw ReaderClientError.invalidReaderResponse
                }
                return ReaderLoadResult(measurement: measurement, readerSHA256: readerHashAfter)
            }.value
        } onCancel: {
            runner.cancel()
        }
    }
    fileprivate static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { digest.update(data: chunk) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func pythonVersion(at python: URL) throws -> String {
        let probe = Process()
        let output = Pipe()
        probe.executableURL = python
        probe.arguments = ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"]
        probe.standardOutput = output
        probe.standardError = FileHandle.nullDevice
        try probe.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard probe.terminationStatus == 0, version.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw ReaderClientError.missingPython
        }
        return version
    }

    private static func pythonExecutable() -> URL? {
        // ponytail: linear scan of fixed candidates, first executable wins — replace with
        // a settings file only if a second site with a different Python layout appears.
        return [
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"
        ].first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private static func configureReaderEnvironment(_ environment: inout [String: String], pythonPath: String?) throws {
        for key in ["PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT"] { environment.removeValue(forKey: key) }
        if let pythonPath, pythonPath != "/usr/bin/env" {
            let version = try pythonVersion(at: URL(fileURLWithPath: pythonPath))
            let userSite = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Python/\(version)/lib/python/site-packages").path
            if FileManager.default.fileExists(atPath: userSite) { environment["PYTHONPATH"] = userSite }
        }
    }

    private static func readOutput(_ handle: FileHandle, limit: Int, exceeded: @escaping @Sendable () -> Void) -> (bytes: Data, exceededLimit: Bool) {
        var bytes = Data()
        var exceededLimit = false
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if bytes.count + chunk.count > limit {
                if !exceededLimit { exceeded() }
                exceededLimit = true
            } else if !exceededLimit {
                bytes.append(chunk)
            }
        }
        return (bytes, exceededLimit)
    }

    private static func readDiagnosticTail(_ handle: FileHandle, limit: Int) -> Data {
        var bytes = Data()
        while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
            bytes.append(chunk)
            if bytes.count > limit { bytes.removeFirst(bytes.count - limit) }
        }
        return bytes
    }

}
