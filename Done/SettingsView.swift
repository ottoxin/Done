import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = LLMSettings.shared
    @State private var claudeKeyVisible = false
    @State private var openAIKeyVisible = false

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(LLMProvider.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.menu)
            }

            switch settings.provider {
            case .claude:
                Section("Claude API Key") {
                    apiKeyField(
                        placeholder: "sk-ant-...",
                        text: $settings.claudeAPIKey,
                        visible: $claudeKeyVisible
                    )
                    Text("Get your key at console.anthropic.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .openAI:
                Section("OpenAI API Key") {
                    apiKeyField(
                        placeholder: "sk-...",
                        text: $settings.openAIAPIKey,
                        visible: $openAIKeyVisible
                    )
                    Text("Get your key at platform.openai.com")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .ollama:
                Section("Ollama") {
                    Text("Run locally: `ollama run qwen3:0.6b`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("ollama.com", destination: URL(string: "https://ollama.com")!)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 260)
    }

    @ViewBuilder
    private func apiKeyField(
        placeholder: String,
        text: Binding<String>,
        visible: Binding<Bool>
    ) -> some View {
        HStack {
            if visible.wrappedValue {
                TextField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField(placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
            Button(visible.wrappedValue ? "Hide" : "Show") {
                visible.wrappedValue.toggle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .font(.caption)
        }
    }
}
