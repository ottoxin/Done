import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = LLMSettings.shared
    @ObservedObject private var chat = ChatService.shared
    @State private var claudeKeyVisible = false
    @State private var openAIKeyVisible = false
    @State private var memoryText = ""
    @State private var showMemorySaved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .padding(.top, 20)

                // AI Provider for task analysis
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("AI Task Analysis", systemImage: "brain")
                            .font(.headline)

                        Picker("Provider", selection: $settings.provider) {
                            ForEach(LLMProvider.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)

                        switch settings.provider {
                        case .claude:
                            apiKeyField(
                                placeholder: "sk-ant-...",
                                text: $settings.claudeAPIKey,
                                visible: $claudeKeyVisible,
                                hint: "Get your key at console.anthropic.com"
                            )

                        case .openAI:
                            apiKeyField(
                                placeholder: "sk-...",
                                text: $settings.openAIAPIKey,
                                visible: $openAIKeyVisible,
                                hint: "Get your key at platform.openai.com"
                            )

                        case .ollama:
                            Text("Run locally: `ollama run qwen3:0.6b`")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(4)
                }

                // Chat CLI provider
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Chat Assistant CLI", systemImage: "terminal")
                            .font(.headline)

                        Text("Choose which CLI to power the in-app chat panel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("CLI", selection: $chat.cliProvider) {
                            ForEach(CLIProvider.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(chat.isAvailable ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(chat.isAvailable
                                 ? "\(chat.cliProvider.rawValue) CLI found"
                                 : "\(chat.cliProvider.rawValue) CLI not found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !chat.isAvailable {
                            Text(chat.cliProvider == .claudeCode
                                 ? "Install: npm install -g @anthropic-ai/claude-code"
                                 : "Install: npm install -g @openai/codex")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.08)))
                        }
                    }
                    .padding(4)
                }

                // Memory file
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Chat Memory", systemImage: "brain.head.profile")
                                .font(.headline)
                            Spacer()
                            if showMemorySaved {
                                Text("Saved")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .transition(.opacity)
                            }
                        }

                        Text("Persistent context shared with the chat assistant across sessions. Stored at ~/.done/memory.md")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $memoryText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 160)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15)))

                        HStack {
                            Spacer()
                            Button("Save Memory") {
                                chat.writeMemory(memoryText)
                                withAnimation { showMemorySaved = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation { showMemorySaved = false }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .onAppear {
            memoryText = chat.readMemory()
        }
    }

    @ViewBuilder
    private func apiKeyField(
        placeholder: String,
        text: Binding<String>,
        visible: Binding<Bool>,
        hint: String
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
        Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
