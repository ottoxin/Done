import Foundation
import Combine

// MARK: - Provider Settings

enum LLMProvider: String, CaseIterable, Identifiable {
    case claude = "Claude (Anthropic)"
    case openAI = "OpenAI"
    case ollama = "Ollama (Local)"

    var id: String { rawValue }
}

final class LLMSettings: ObservableObject {
    static let shared = LLMSettings()

    // Provider choice is non-sensitive → UserDefaults is fine
    @Published var provider: LLMProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "llmProvider") }
    }
    // API keys → Keychain
    @Published var claudeAPIKey: String {
        didSet { Keychain.save(claudeAPIKey, forKey: "claudeAPIKey") }
    }
    @Published var openAIAPIKey: String {
        didSet { Keychain.save(openAIAPIKey, forKey: "openAIAPIKey") }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "llmProvider") ?? LLMProvider.claude.rawValue
        self.provider   = LLMProvider(rawValue: raw) ?? .claude
        self.claudeAPIKey  = Keychain.load(forKey: "claudeAPIKey")  ?? ""
        self.openAIAPIKey  = Keychain.load(forKey: "openAIAPIKey")  ?? ""
    }
}

// MARK: - Protocol

protocol LLMServiceProtocol {
    func analyzeTask(title: String) async -> TaskAnalysis?
    func getFocusTip(title: String) async -> String
}

// MARK: - Claude (Anthropic)

final class ClaudeService: LLMServiceProtocol {
    private let apiKey: String
    private let model = "claude-3-5-haiku-20241022"

    init(apiKey: String) { self.apiKey = apiKey }

    private func complete(prompt: String) async -> String? {
        guard !apiKey.isEmpty,
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let content = (json["content"] as? [[String: Any]])?.first,
               let text = content["text"] as? String {
                return text
            }
        } catch {
            print("Claude API error: \(error)")
        }
        return nil
    }

    func analyzeTask(title: String) async -> TaskAnalysis? {
        let prompt = taskAnalysisPrompt(title: title)
        guard let raw = await complete(prompt: prompt) else { return nil }
        return decode(raw)
    }

    func getFocusTip(title: String) async -> String {
        let prompt = "Task: \"\(title)\". Give 1 very short micro-strategy (under 10 words) to start. Be motivating. Reply with only the tip."
        return await complete(prompt: prompt) ?? "Just take the first step."
    }
}

// MARK: - OpenAI

final class OpenAIService: LLMServiceProtocol {
    private let apiKey: String
    private let model = "gpt-4o-mini"

    init(apiKey: String) { self.apiKey = apiKey }

    private func complete(prompt: String) async -> String? {
        guard !apiKey.isEmpty,
              let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 300,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content
            }
        } catch {
            print("OpenAI API error: \(error)")
        }
        return nil
    }

    func analyzeTask(title: String) async -> TaskAnalysis? {
        let prompt = taskAnalysisPrompt(title: title)
        guard let raw = await complete(prompt: prompt) else { return nil }
        return decode(raw)
    }

    func getFocusTip(title: String) async -> String {
        let prompt = "Task: \"\(title)\". Give 1 very short micro-strategy (under 10 words) to start. Be motivating. Reply with only the tip."
        return await complete(prompt: prompt) ?? "Just take the first step."
    }
}

// MARK: - Ollama conformance (kept optional)

extension OllamaService: LLMServiceProtocol {}

// MARK: - Shared helpers

private func taskAnalysisPrompt(title: String) -> String {
    """
    You are a strict JSON generator and realistic time estimator.

    Task: "\(title)"

    Return ONLY valid JSON matching this schema exactly:
    {
      "difficulty": <integer 1-5>,
      "isComplex": <boolean>,
      "estimatedMinutes": <realistic integer minutes to complete this specific task>,
      "subtasks": <array of 0-3 strings>
    }

    Rules:
    - No markdown, no comments, no extra keys, no extra text.
    - difficulty: 1=trivial, 2=easy, 3=medium, 4=hard, 5=very hard.
    - estimatedMinutes: be realistic, not optimistic. A grocery run is 45, writing a report is 90, replying to an email is 5.
    - If no subtasks, return "subtasks": [].
    - Each subtask string: trim spaces, capitalize first letter if English.
    """
}

private func decode(_ raw: String) -> TaskAnalysis? {
    let cleaned = raw.extractFirstJSONObject() ?? raw
    guard let data = cleaned.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(TaskAnalysis.self, from: data)
}

// MARK: - Factory

func makeLLMService() -> LLMServiceProtocol {
    let s = LLMSettings.shared
    switch s.provider {
    case .claude:  return ClaudeService(apiKey: s.claudeAPIKey)
    case .openAI:  return OpenAIService(apiKey: s.openAIAPIKey)
    case .ollama:  return OllamaService()
    }
}
