import AppKit
import Foundation

struct UsageStoryboard: Codable, Equatable, Sendable {
    static let requiredRanges = ["0-24", "25-49", "50-74", "75-100"]

    struct Stage: Codable, Equatable, Sendable {
        let usageRange: String
        let action: String
        let emotion: String
    }

    let title: String
    let characterInvariants: [String]
    let stages: [Stage]

    var isValid: Bool {
        stages.map(\.usageRange) == Self.requiredRanges &&
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            characterInvariants.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } &&
            stages.allSatisfy {
                !$0.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    !$0.emotion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }
}

enum UsageThemeGenerationError: LocalizedError {
    case codexUnavailable
    case codexNotConnected
    case invalidStoryboard
    case imageGenerationUnavailable(String)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexUnavailable:
            "Codex CLI was not found. Install Codex or make it available in your interactive shell."
        case .codexNotConnected:
            "Codex CLI is not connected. Sign in or configure your provider in Codex, then try again."
        case .invalidStoryboard:
            "Codex did not return a valid four-stage storyboard."
        case .imageGenerationUnavailable(let detail):
            detail.isEmpty
                ? "Your current Codex provider does not expose the built-in image generator."
                : detail
        case .requestFailed(let message):
            message
        }
    }
}

struct CodexCLICommandResult: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
    let didTimeOut: Bool
}

protocol CodexCLIExecuting: Sendable {
    func run(command: String, input: String, timeout: TimeInterval) async throws -> CodexCLICommandResult
}

struct CodexCLIExecutor: CodexCLIExecuting {
    func run(command: String, input: String, timeout: TimeInterval) async throws -> CodexCLICommandResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.runSynchronously(command: command, input: input, timeout: timeout)
        }.value
    }

    static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func runSynchronously(
        command: String,
        input: String,
        timeout: TimeInterval
    ) throws -> CodexCLICommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ic", command]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["HISTFILE"] = "/dev/null"
        process.environment = environment

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let output = ThreadSafeDataBox()
        let errors = ThreadSafeDataBox()
        let didTimeOut = ThreadSafeBoolBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            output.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errors.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        do {
            try process.run()
        } catch {
            inputPipe.fileHandleForWriting.closeFile()
            throw UsageThemeGenerationError.codexUnavailable
        }

        inputPipe.fileHandleForWriting.write(Data(input.utf8))
        inputPipe.fileHandleForWriting.closeFile()

        let timeoutWork = DispatchWorkItem {
            guard process.isRunning else { return }
            didTimeOut.setTrue()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        process.waitUntilExit()
        timeoutWork.cancel()
        readers.wait()

        return CodexCLICommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: output.value, encoding: .utf8) ?? "",
            standardError: String(data: errors.value, encoding: .utf8) ?? "",
            didTimeOut: didTimeOut.value
        )
    }
}

struct UsageThemeGenerator: Sendable {
    private let executor: any CodexCLIExecuting

    init(executor: any CodexCLIExecuting = CodexCLIExecutor()) {
        self.executor = executor
    }

    func checkCodexConnection() async throws {
        let command = "command -v codex >/dev/null 2>&1 && codex login status >/dev/null 2>&1"
        let result = try await executor.run(command: command, input: "", timeout: 20)
        guard result.exitCode == 0 else {
            if result.standardError.localizedCaseInsensitiveContains("command not found") {
                throw UsageThemeGenerationError.codexUnavailable
            }
            throw UsageThemeGenerationError.codexNotConnected
        }
    }

    func createStoryboard(description: String) async throws -> UsageStoryboard {
        let workspace = try makeWorkspace()
        let schemaURL = workspace.appendingPathComponent("storyboard-schema.json")
        let outputURL = workspace.appendingPathComponent("storyboard.json")
        try Self.storyboardSchema.write(to: schemaURL, options: .atomic)

        let prompt = """
        Return a JSON storyboard for exactly four progressive usage-theme images.

        User idea: \(description)

        The four ranges must be 0-24, 25-49, 50-74, and 75-100. Keep character identity,
        art style, proportions, colors, clothing, accessories, camera, framing, and lighting
        consistent. Every stage must meaningfully change the character's expression, pose,
        action, and the consumed or changing object's state. No text, labels, grids, borders,
        logos, or watermarks may appear in the images.
        """
        let command = Self.codexCommand(
            workspace: workspace,
            outputURL: outputURL,
            schemaURL: schemaURL
        )
        let result = try await executor.run(command: command, input: prompt, timeout: 120)
        guard result.exitCode == 0 else { throw Self.commandError(from: result) }
        guard let data = try? Data(contentsOf: outputURL),
              let storyboard = Self.decodeStoryboard(data),
              storyboard.isValid else {
            throw UsageThemeGenerationError.invalidStoryboard
        }
        return storyboard
    }

    func generateFrames(
        description: String,
        storyboard: UsageStoryboard,
        referenceImage: Data?
    ) async throws -> [Data] {
        let workspace = try makeWorkspace()
        let outputURL = workspace.appendingPathComponent("generation-result.txt")
        var referenceURL: URL?
        if let referenceImage {
            let url = workspace.appendingPathComponent("reference-image.png")
            try referenceImage.write(to: url, options: .atomic)
            referenceURL = url
        }

        let storyboardJSON = try JSONEncoder().encode(storyboard)
        let storyboardText = String(data: storyboardJSON, encoding: .utf8) ?? "{}"
        let frameNames = (1...UsageTheme.frameCount).map { "frame-\($0).png" }
        let prompt = """
        Use the installed imagegen skill and its built-in image_gen tool to create exactly four
        separate square PNG usage-animation frames. Make one image_gen call per frame. Do not use
        the fallback Python/API script and do not ask for an API key.

        User idea: \(description)
        Storyboard JSON: \(storyboardText)

        Preserve the storyboard's character invariants, art style, proportions, colors, clothing,
        accessories, camera, framing, and lighting across all four frames. Change the character's
        expression, pose, action, and prop state in every frame. Do not add text, labels, grids,
        borders, logos, or watermarks.

        \(referenceURL == nil
            ? "Generate frame 1 first as the identity reference, then use that generated character as the reference for frames 2 through 4."
            : "Use the attached image only as the immutable character identity and style reference for all four frames.")

        Copy the four final PNG files into this working directory using these exact filenames:
        \(frameNames.joined(separator: ", ")). Do not modify any source code or create other project files.
        """

        let command = Self.codexCommand(
            workspace: workspace,
            outputURL: outputURL,
            referenceURL: referenceURL,
            enableImageGeneration: true
        )
        let result = try await executor.run(command: command, input: prompt, timeout: 12 * 60)
        guard result.exitCode == 0 else { throw Self.commandError(from: result) }

        var frames: [Data] = []
        for frameName in frameNames {
            let url = workspace.appendingPathComponent(frameName)
            guard let data = try? Data(contentsOf: url),
                  data.count <= UsageThemeStore.maximumImageBytes,
                  let image = NSImage(data: data), image.isValid else {
                let detail = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? result.standardOutput
                throw UsageThemeGenerationError.imageGenerationUnavailable(
                    Self.imageFailureMessage(from: detail)
                )
            }
            frames.append(data)
        }
        return frames
    }

    static func decodeStoryboard(_ data: Data) -> UsageStoryboard? {
        if let storyboard = try? JSONDecoder().decode(UsageStoryboard.self, from: data) {
            return storyboard
        }
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
            if text.hasSuffix("```") { text.removeLast(3) }
        }
        return text.data(using: .utf8).flatMap { try? JSONDecoder().decode(UsageStoryboard.self, from: $0) }
    }

    static func imageFailureMessage(from output: String) -> String {
        let sanitized = sanitize(output)
        if sanitized.localizedCaseInsensitiveContains("image_gen") &&
            sanitized.localizedCaseInsensitiveContains("not available") {
            return "Your current Codex provider does not expose the built-in image generator. Manual four-frame import is still available."
        }
        if sanitized.localizedCaseInsensitiveContains("no image was generated") {
            return "Codex completed without generating images. Your current provider may not support image generation."
        }
        return sanitized.isEmpty
            ? "Codex did not create all four frames. Your current provider may not support image generation."
            : String(sanitized.suffix(800))
    }

    static func sanitize(_ output: String) -> String {
        output.replacingOccurrences(
            of: #"sk-[A-Za-z0-9_-]{8,}"#,
            with: "sk-***",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeWorkspace() throws -> URL {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("open-island-codex-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private static func codexCommand(
        workspace: URL,
        outputURL: URL,
        schemaURL: URL? = nil,
        referenceURL: URL? = nil,
        enableImageGeneration: Bool = false
    ) -> String {
        var arguments = [
            "codex", "-a", "never", "exec", "--skip-git-repo-check", "--ephemeral", "--json", "--color", "never",
            "-s", enableImageGeneration ? "workspace-write" : "read-only",
            "-c", "model_reasoning_effort=\"low\"",
            "-C", CodexCLIExecutor.shellQuote(workspace.path),
            "-o", CodexCLIExecutor.shellQuote(outputURL.path),
        ]
        if enableImageGeneration { arguments += ["--enable", "image_generation"] }
        if let schemaURL { arguments += ["--output-schema", CodexCLIExecutor.shellQuote(schemaURL.path)] }
        if let referenceURL { arguments += ["-i", CodexCLIExecutor.shellQuote(referenceURL.path)] }
        arguments.append("-")
        return arguments.joined(separator: " ")
    }

    private static func commandError(from result: CodexCLICommandResult) -> UsageThemeGenerationError {
        if result.didTimeOut {
            return .requestFailed("Codex CLI timed out before completing the generation request.")
        }
        let combined = sanitize(result.standardOutput + "\n" + result.standardError)
        if combined.localizedCaseInsensitiveContains("not logged in") ||
            combined.localizedCaseInsensitiveContains("unauthorized") ||
            combined.localizedCaseInsensitiveContains("invalid_api_key") {
            return .codexNotConnected
        }
        return .requestFailed(
            combined.isEmpty ? "Codex CLI exited with status \(result.exitCode)." : String(combined.suffix(800))
        )
    }

    private static let storyboardSchema = Data(#"""
    {
      "type": "object",
      "additionalProperties": false,
      "required": ["title", "characterInvariants", "stages"],
      "properties": {
        "title": { "type": "string" },
        "characterInvariants": {
          "type": "array",
          "minItems": 1,
          "items": { "type": "string" }
        },
        "stages": {
          "type": "array",
          "minItems": 4,
          "maxItems": 4,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["usageRange", "action", "emotion"],
            "properties": {
              "usageRange": { "type": "string" },
              "action": { "type": "string" },
              "emotion": { "type": "string" }
            }
          }
        }
      }
    }
    """#.utf8)
}

private final class ThreadSafeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.withLock { data }
    }

    func set(_ newValue: Data) {
        lock.withLock { data = newValue }
    }
}

private final class ThreadSafeBoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func setTrue() {
        lock.withLock { storage = true }
    }
}
