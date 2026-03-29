import SwiftUI

/// Chat panel that connects to Claude Code or Codex CLI.
struct ChatView: View {
    @StateObject private var chat = ChatService.shared
    @State private var input = ""
    @State private var showMemory = false
    @State private var memoryText = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.cliProvider.rawValue)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    HStack(spacing: 4) {
                        Circle()
                            .fill(chat.isAvailable ? Color.green : Color.red)
                            .frame(width: 6, height: 6)
                        Text(chat.isAvailable ? "Available" : "Not found")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Memory button
                Button {
                    memoryText = chat.readMemory()
                    showMemory.toggle()
                } label: {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit memory file")

                // Clear button
                Button {
                    chat.clearHistory()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear chat history")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty {
                            emptyState
                                .padding(.top, 40)
                        }

                        ForEach(chat.messages) { msg in
                            messageBubble(msg)
                                .id(msg.id)
                        }

                        if chat.isStreaming {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // Input
            HStack(spacing: 10) {
                TextField("Ask anything...", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                    .onSubmit { sendMessage() }
                #if os(macOS)
                    .modifier(DisableFocusRingIfAvailable())
                #endif

                if chat.isStreaming {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary.opacity(0.3) : Color.blue)
                    }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isStreaming)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showMemory) {
            memoryEditor
        }
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isStreaming else { return }
        input = ""
        chat.send(text)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.5))

            Text("Chat with \(chat.cliProvider.rawValue)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Add tasks, ask questions, or manage your day through conversation.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            if !chat.isAvailable {
                VStack(spacing: 6) {
                    Text("\(chat.cliProvider.rawValue) CLI not installed")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(chat.cliProvider == .claudeCode
                         ? "npm install -g @anthropic-ai/claude-code"
                         : "npm install -g @openai/codex")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Message bubble

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer()
                Text(msg.text)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 12)

        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: chat.cliProvider == .claudeCode ? "sparkle" : "brain")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                if msg.text.isEmpty {
                    Text("...")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                } else {
                    Text(msg.text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 12)

        case .system:
            HStack {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(msg.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Memory editor

    private var memoryEditor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat Memory")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    chat.writeMemory(memoryText)
                    showMemory = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Cancel") {
                    showMemory = false
                }
                .controlSize(.small)
            }
            .padding()

            Divider()

            TextEditor(text: $memoryText)
                .font(.system(size: 13, design: .monospaced))
                .padding(8)
        }
        .frame(width: 500, height: 400)
    }
}
