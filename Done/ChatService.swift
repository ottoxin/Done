import Foundation
import Combine

/// A single message in the chat conversation.
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ChatRole
    var text: String
    let timestamp: Date

    enum ChatRole: String {
        case user, assistant, system
    }

    init(role: ChatRole, text: String) {
        self.role = role
        self.text = text
        self.timestamp = Date()
    }
}

/// Which CLI to use for the chat interface.
enum CLIProvider: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code"
    case codex = "Codex"

    var id: String { rawValue }

    var command: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }
}

/// Manages CLI chat sessions and memory file.
@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    @Published var messages: [ChatMessage] = []
    @Published var isStreaming = false
    @Published var isAvailable = false

    @Published var cliProvider: CLIProvider {
        didSet { UserDefaults.standard.set(cliProvider.rawValue, forKey: "chatCLIProvider"); checkAvailability() }
    }

    /// Memory file path — persistent context for the chat assistant.
    static let memoryURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".done")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "memory.md")
    }()

    private init() {
        let raw = UserDefaults.standard.string(forKey: "chatCLIProvider") ?? CLIProvider.claudeCode.rawValue
        self.cliProvider = CLIProvider(rawValue: raw) ?? .claudeCode
        checkAvailability()
        ensureMemoryFile()
    }

    /// Check if the selected CLI is installed and accessible.
    func checkAvailability() {
        let cmd = cliProvider.command
        Task { @MainActor in
            let result = await Task.detached { Self.findCLI(cmd) }.value
            self.isAvailable = result != nil
        }
    }

    /// Find a CLI command by checking well-known paths (macOS apps don't inherit shell PATH).
    nonisolated private static func findCLI(_ command: String) -> String? {
        // Direct path checks — most reliable for sandboxed/Launchpad apps
        let searchPaths = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "\(NSHomeDirectory())/.npm-global/bin/\(command)",
        ]
        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Check nvm paths
        let nvmBase = "\(NSHomeDirectory())/.nvm/versions/node"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: nvmBase) {
            for entry in contents.sorted().reversed() {
                let candidate = "\(nvmBase)/\(entry)/bin/\(command)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        // Fallback: try /usr/bin/which (works when run from Xcode, not Launchpad)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [command]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }

    /// Ensure memory file exists with a default header.
    private func ensureMemoryFile() {
        let url = Self.memoryURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let header = """
        # Done — Chat Memory

        This file is shared context for the Done app's chat assistant.
        Add notes, preferences, or context you want the assistant to remember across sessions.

        ---


        """
        try? header.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Read the memory file contents.
    func readMemory() -> String {
        (try? String(contentsOf: Self.memoryURL, encoding: .utf8)) ?? ""
    }

    /// Write to the memory file.
    func writeMemory(_ content: String) {
        try? content.write(to: Self.memoryURL, atomically: true, encoding: .utf8)
    }

    /// Send a message to the selected CLI.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        isStreaming = true

        let placeholder = ChatMessage(role: .assistant, text: "")
        messages.append(placeholder)
        let placeholderID = placeholder.id

        let provider = cliProvider
        let memory = readMemory()

        Task { @MainActor in
            let response = await Task.detached {
                await Self.runCLI(provider: provider, prompt: trimmed, memory: memory)
            }.value
            if let idx = self.messages.firstIndex(where: { $0.id == placeholderID }) {
                self.messages[idx].text = response
            }
            self.isStreaming = false
        }
    }

    /// Run the CLI command.
    private static func runCLI(provider: CLIProvider, prompt: String, memory: String) async -> String {
        let command = provider.command

        let execPath = findCLI(command)

        guard let path = execPath else {
            return "\(provider.rawValue) CLI not found. Install it first:\n" +
                   (provider == .claudeCode
                    ? "npm install -g @anthropic-ai/claude-code"
                    : "npm install -g @openai/codex")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)

        // Build the prompt with memory context
        var fullPrompt = prompt
        if !memory.isEmpty {
            fullPrompt = "Context from memory file:\n\(memory)\n\n---\nUser request: \(prompt)"
        }

        switch provider {
        case .claudeCode:
            proc.arguments = ["--print", fullPrompt]
        case .codex:
            proc.arguments = ["--quiet", "--full-auto", fullPrompt]
        }

        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/usr/local/bin", "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.npm-global/bin"
        ]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if !output.isEmpty { return output }
            if !errorOutput.isEmpty { return "Error: \(errorOutput)" }
            return "No response."
        } catch {
            return "Failed to run \(provider.rawValue): \(error.localizedDescription)"
        }
    }

    func clearHistory() {
        messages.removeAll()
    }
}
