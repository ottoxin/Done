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

    @Published var cliPathOverride: String {
        didSet { UserDefaults.standard.set(cliPathOverride, forKey: "chatCLIPathOverride"); checkAvailability() }
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
        self.cliPathOverride = UserDefaults.standard.string(forKey: "chatCLIPathOverride") ?? ""
        checkAvailability()
        ensureMemoryFile()
        syncCLAUDEmd()
    }

    /// Check if the selected CLI is installed and accessible.
    func checkAvailability() {
        let cmd = cliProvider.command
        let override = cliPathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let result = await Task.detached { Self.findCLI(cmd, override: override) }.value
            self.isAvailable = result != nil
        }
    }

    /// Find a CLI command by checking well-known paths (macOS apps don't inherit shell PATH).
    nonisolated private static func findCLI(_ command: String, override: String = "") -> String? {
        // Check manual override first
        if !override.isEmpty && FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
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

    /// Write CLAUDE.md to home directory so the CLI picks up the app bridge instructions.
    private func syncCLAUDEmd() {
        let dest = FileManager.default.homeDirectoryForCurrentUser.appending(path: "CLAUDE.md")
        try? claudeMdContent.write(to: dest, atomically: true, encoding: .utf8)
    }

    private let claudeMdContent = """
    # Done — AI Planning Assistant

    You are helping the user manage their day using the Done app (a native macOS todo/time manager).

    ## How it works

    The app writes its live state to `~/.done/state.json` whenever tasks change.
    You read that file to understand the current situation, then write `~/.done/updates.json` to make changes.
    The app watches for `updates.json` and applies it automatically — usually within 2 seconds.

    ## Reading current state

    ```bash
    cat ~/.done/state.json
    ```

    Fields:
    - `date` — today's date
    - `freeMinutesToday` — total free time left today (after calendar events)
    - `tasks[]` — each task has:
      - `title`, `difficulty` (1–5), `isComplex`, `isCompleted`, `sortOrder` (0 = top)
      - `isToday` — true = planned for today, false = someday/waitlist
      - `estimatedMinutes` — AI or heuristic time estimate
      - `scheduledStart` / `scheduledEnd` — ISO8601, null if not yet scheduled
      - `project` — project/category name (string or null)

    ## Writing updates

    Write a JSON file to `~/.done/updates.json`. The app applies it and deletes the file.

    ```json
    {
      "timestamp": "<ISO8601 now>",
      "message": "A short note shown to the user in the app (optional)",
      "changes": [
        ...
      ]
    }
    ```

    ### Change types

    **Add a task**
    ```json
    { "type": "add", "title": "Buy coffee", "difficulty": 1, "isComplex": false, "project": "Personal" }
    ```

    **Complete a task**
    ```json
    { "type": "complete", "title": "Write proposal" }
    ```

    **Delete a task**
    ```json
    { "type": "delete", "title": "Old task" }
    ```

    **Reorder** (sortOrder 0 = top of list)
    ```json
    { "type": "reorder", "title": "Buy groceries", "sortOrder": 0 }
    ```

    **Change difficulty** (1 = 15 min, 2 = 25 min, 3 = 45 min, 4 = 60 min, 5 = 90 min)
    ```json
    { "type": "setDifficulty", "title": "Refactor UI", "difficulty": 2 }
    ```

    **Reschedule** (override the app's auto-schedule for a task)
    ```json
    { "type": "reschedule", "title": "Write proposal", "scheduledStart": "2026-03-23T14:00:00Z", "scheduledEnd": "2026-03-23T15:00:00Z" }
    ```

    **Set project** (assign or change a task's project/category)
    ```json
    { "type": "setProject", "title": "Write proposal", "project": "Research" }
    ```

    ## Rules
    - Match tasks by title (case-insensitive). Don't invent tasks that aren't in state.json.
    - Keep `message` short (1–2 sentences). The user sees it as an alert in the app.
    - Difficulty affects estimated time: 1→15m, 2→25m, 3→45m, 4→60m, 5→90m
    - Don't write updates.json unless the user explicitly wants changes made.
    - ALWAYS write updates.json when the user asks to add, complete, delete, or change tasks.
    """

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
        let override = cliPathOverride.trimmingCharacters(in: .whitespacesAndNewlines)

        Task { @MainActor in
            let response = await Task.detached {
                await Self.runCLI(provider: provider, prompt: trimmed, memory: memory, pathOverride: override)
            }.value
            if let idx = self.messages.firstIndex(where: { $0.id == placeholderID }) {
                self.messages[idx].text = response
            }
            self.isStreaming = false
        }
    }

    /// Run the CLI command.
    private static func runCLI(provider: CLIProvider, prompt: String, memory: String, pathOverride: String = "") async -> String {
        let command = provider.command

        let execPath = findCLI(command, override: pathOverride)

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
