import Foundation

public struct IndexCommandOptions: Equatable, Sendable {
    public let projectURL: URL
    public let dataRoot: String?
    public let saveSettings: Bool
    public let rebuild: Bool
    public let jsonOutput: Bool

    public init(
        projectURL: URL,
        dataRoot: String? = nil,
        saveSettings: Bool = false,
        rebuild: Bool = false,
        jsonOutput: Bool = false
    ) {
        self.projectURL = projectURL
        self.dataRoot = dataRoot
        self.saveSettings = saveSettings
        self.rebuild = rebuild
        self.jsonOutput = jsonOutput
    }
}

public enum IndexCommandExitCode: Int32, Sendable {
    case success = 0
    case incompleteOrFatal = 1
    case configurationOrArguments = 2
    case writerBusy = 3
    case interrupt = 130
}

public enum IndexCommandError: Error, LocalizedError, Equatable {
    case missingProjectArgument
    case unknownFlag(String)
    case missingFlagValue(String)
    case saveSettingsRequiresDataRoot
    case dataRootMustBeRelative(String)
    case outsideProjectBoundary(String)
    case missingConfiguration(String)
    case malformedConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .missingProjectArgument:
            return "Missing required --project <path> argument."
        case let .unknownFlag(flag):
            return "Unknown option: \(flag)"
        case let .missingFlagValue(flag):
            return "Option \(flag) requires a value."
        case .saveSettingsRequiresDataRoot:
            return "--save-settings requires --data-root to be specified."
        case let .dataRootMustBeRelative(path):
            return "--data-root must be a relative path within the project: '\(path)'"
        case let .outsideProjectBoundary(path):
            return "--data-root escapes project boundary: '\(path)'"
        case let .missingConfiguration(msg):
            return "Missing project configuration: \(msg). Provide --data-root or configure settings."
        case let .malformedConfiguration(msg):
            return "Malformed project configuration: \(msg). Provide explicit --data-root to override."
        }
    }
}

public enum IndexCommand {
    public static func parse(_ arguments: [String]) throws -> IndexCommandOptions {
        var projectPath: String?
        var dataRoot: String?
        var saveSettings = false
        var rebuild = false
        var jsonOutput = false

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--project", "-p":
                index += 1
                guard index < arguments.count else {
                    throw IndexCommandError.missingFlagValue(arg)
                }
                projectPath = arguments[index]
            case "--data-root", "-d":
                index += 1
                guard index < arguments.count else {
                    throw IndexCommandError.missingFlagValue(arg)
                }
                dataRoot = arguments[index]
            case "--save-settings":
                saveSettings = true
            case "--rebuild":
                rebuild = true
            case "--json":
                jsonOutput = true
            default:
                if arg.hasPrefix("-") {
                    throw IndexCommandError.unknownFlag(arg)
                } else if projectPath == nil {
                    projectPath = arg
                } else {
                    throw IndexCommandError.unknownFlag(arg)
                }
            }
            index += 1
        }

        guard let rawProjectPath = projectPath, !rawProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IndexCommandError.missingProjectArgument
        }

        if saveSettings && dataRoot == nil {
            throw IndexCommandError.saveSettingsRequiresDataRoot
        }

        if let dataRoot {
            if dataRoot.hasPrefix("/") {
                throw IndexCommandError.dataRootMustBeRelative(dataRoot)
            }
            let components = dataRoot.split(separator: "/")
            if components.contains("..") {
                throw IndexCommandError.outsideProjectBoundary(dataRoot)
            }
        }

        let projectURL = URL(fileURLWithPath: rawProjectPath).standardizedFileURL
        return IndexCommandOptions(
            projectURL: projectURL,
            dataRoot: dataRoot,
            saveSettings: saveSettings,
            rebuild: rebuild,
            jsonOutput: jsonOutput
        )
    }

    /// Resolves the effective project context according to command options and settings policy:
    /// - If --data-root is specified, validates it; if --save-settings, saves to disk.
    /// - If --data-root is omitted, loads existing settings. Missing/corrupted settings throw configuration errors (exit 2).
    public static func resolveProject(options: IndexCommandOptions) throws -> ProjectContext {
        let projectRoot = options.projectURL

        if let explicitRoot = options.dataRoot {
            if options.saveSettings {
                let settings = ProjectSettings(dataRoot: explicitRoot, defaultView: "tree")
                try ProjectSettingsStore.save(settings, projectRoot: projectRoot)
            }
            return try ProjectContext.open(projectRoot, dataRootRelativePath: explicitRoot)
        } else {
            let settings: ProjectSettings?
            do {
                settings = try ProjectSettingsStore.load(projectRoot: projectRoot)
            } catch let err as ProjectSettingsError {
                throw IndexCommandError.malformedConfiguration(err.reason)
            } catch {
                throw IndexCommandError.malformedConfiguration(error.localizedDescription)
            }

            guard let validSettings = settings else {
                throw IndexCommandError.missingConfiguration("No .rawviewer/setting.yaml found")
            }
            return try ProjectContext.open(projectRoot, dataRootRelativePath: validSettings.dataRoot)
        }
    }

    /// Executes the indexing command end-to-end and returns the exit code and report.
    public static func run(
        options: IndexCommandOptions,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> (report: ProjectIndexRunReport?, exitCode: IndexCommandExitCode) {
        do {
            let project = try resolveProject(options: options)
            let report = try await ProjectIndexer.run(
                project: project,
                rebuild: options.rebuild,
                onProgress: onProgress
            )
            let code: IndexCommandExitCode = (report.complete && report.cancelled == 0) ? .success : .incompleteOrFatal
            return (report, code)
        } catch let err as IndexCommandError {
            fputs("Error: \(err.localizedDescription)\n", stderr)
            return (nil, .configurationOrArguments)
        } catch let err as ProjectSettingsError {
            fputs("Error: \(err.reason)\n", stderr)
            return (nil, .configurationOrArguments)
        } catch ProjectIndexStore.StoreError.busy {
            fputs("Error: Project index writer lease is busy.\n", stderr)
            return (nil, .writerBusy)
        } catch ReaderError.invalidProject {
            fputs("Error: Invalid project or data root directory.\n", stderr)
            return (nil, .configurationOrArguments)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return (nil, .incompleteOrFatal)
        }
    }
}
