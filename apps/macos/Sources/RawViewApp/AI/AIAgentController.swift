import Foundation

/// Controller managing subprocess execution of AI CLI tools (OpenCode CLI and Codex CLI).
public final class AIAgentController: ObservableObject, @unchecked Sendable {
    @Published public private(set) var isRunning: Bool = false
    private var activeProcess: Process?

    public init() {}

    public static func resolveBinary(for provider: String) -> String? {
        let isCodex = provider.lowercased().contains("codex")
        let binaryName = isCodex ? "codex" : "opencode"

        let candidatePaths = [
            "/opt/homebrew/bin/\(binaryName)",
            "/usr/local/bin/\(binaryName)",
            "\(NSHomeDirectory())/.\(binaryName)/bin/\(binaryName)",
            "/usr/bin/\(binaryName)"
        ]

        return candidatePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    public func run(
        prompt: String,
        provider: String,
        model: String,
        reasoningEffort: String = "medium",
        projectRoot: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard !isRunning else {
            completion(.failure(NSError(domain: "AIAgentController", code: 1, userInfo: [NSLocalizedDescriptionKey: "An AI task is already executing."])))
            return
        }

        guard let binaryPath = Self.resolveBinary(for: provider) else {
            completion(.failure(NSError(domain: "AIAgentController", code: 2, userInfo: [NSLocalizedDescriptionKey: "Binary for \(provider) not found in standard paths."])))
            return
        }

        let isCodex = provider.lowercased().contains("codex")
        var arguments: [String] = []

        if isCodex {
            // Codex CLI non-interactive execution with reasoning effort
            arguments = [
                "exec",
                "--cd", projectRoot.path,
                "-m", model,
                "--dangerously-bypass-approvals-and-sandbox"
            ]
            if reasoningEffort != "off" {
                arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"\(reasoningEffort)\""])
            }
            arguments.append(prompt)
        } else {
            // OpenCode CLI runner with valid reasoning variants
            var finalModel = model
            if !model.contains("#") && reasoningEffort != "off" && !reasoningEffort.isEmpty {
                finalModel = "\(model)#\(reasoningEffort)"
            }
            arguments = ["run", "--standalone", "--auto"]
            if !finalModel.isEmpty {
                arguments.append(contentsOf: ["--model", finalModel])
            }
            arguments.append(prompt)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        process.currentDirectoryURL = projectRoot

        var env = ProcessInfo.processInfo.environment
        let path = env["PATH"] ?? ""
        if !path.contains("/opt/homebrew/bin") {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + path
        }
        if let goKey = Preferences.shared.apiKey(for: "opencode-go"), !goKey.isEmpty {
            env["OPENCODE_API_KEY"] = goKey
            env["OPENCODE_GO_API_KEY"] = goKey
        }
        if let codexKey = Preferences.shared.apiKey(for: "openai-codex"), !codexKey.isEmpty {
            env["OPENAI_API_KEY"] = codexKey
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        self.activeProcess = process
        self.isRunning = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                var outData = Data()
                var errData = Data()
                let readGroup = DispatchGroup()

                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outData = stdoutHandle.readDataToEndOfFile()
                    readGroup.leave()
                }

                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errData = stderrHandle.readDataToEndOfFile()
                    readGroup.leave()
                }

                try process.run()
                process.waitUntilExit()
                readGroup.wait()

                let outStr = String(data: outData, encoding: .utf8) ?? ""
                let errStr = String(data: errData, encoding: .utf8) ?? ""

                DispatchQueue.main.async {
                    self.isRunning = false
                    self.activeProcess = nil

                    if process.terminationStatus == 0 {
                        let finalOutput = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
                        completion(.success(finalOutput.isEmpty ? "Task completed." : finalOutput))
                    } else {
                        let errMsg = errStr.isEmpty ? "Process exited with code \(process.terminationStatus)" : errStr
                        completion(.failure(NSError(domain: "AIAgentController", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg])))
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.activeProcess = nil
                    completion(.failure(error))
                }
            }
        }
    }

    public func stop() {
        activeProcess?.terminate()
        activeProcess = nil
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }
}
