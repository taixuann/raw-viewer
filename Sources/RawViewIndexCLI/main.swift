import Foundation
import RawViewCore

@main
struct RawViewIndexCLI {
    static func main() async {
        // Handle SIGINT gracefully with exit code 130
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler {
            fputs("\nInterrupted.\n", stderr)
            exit(IndexCommandExitCode.interrupt.rawValue)
        }
        signal(SIGINT, SIG_IGN)
        sigintSource.resume()

        let arguments = Array(CommandLine.arguments.dropFirst())
        let options: IndexCommandOptions
        do {
            options = try IndexCommand.parse(arguments)
        } catch let err as IndexCommandError {
            fputs("Error: \(err.localizedDescription)\n", stderr)
            exit(IndexCommandExitCode.configurationOrArguments.rawValue)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(IndexCommandExitCode.configurationOrArguments.rawValue)
        }

        let (report, exitCode) = await IndexCommand.run(options: options) { current, total in
            fputs("Indexing batch \(current)/\(total)\r", stderr)
            fflush(stderr)
        }

        if let report {
            if options.jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(report), let jsonStr = String(data: data, encoding: .utf8) {
                    print(jsonStr)
                }
            } else {
                print("Index summary:")
                print("  Discovered: \(report.discovered)")
                print("  Inspected: \(report.inspected)")
                print("  Deterministic Blocked: \(report.deterministicBlocked)")
                print("  Structural Candidates: \(report.structuralCandidates)")
                print("  Transient Failures: \(report.transientFailures)")
                print("  Inventory Failures: \(report.inventoryFailures)")
                print("  Cancelled: \(report.cancelled)")
                print("  Complete: \(report.complete)")
                print("  Storage Mode: \(report.storageMode.rawValue)")
            }
        }

        exit(exitCode.rawValue)
    }
}
