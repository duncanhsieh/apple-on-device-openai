//
//  ChatView.swift
//  AppleOnDeviceOpenAI
//

import Combine
import FoundationModels
import SwiftUI

let chatWindowID = "chat"

// MARK: - Models
struct ChatEntry: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var isError = false
}

// MARK: - ViewModel
/// Talks to the selected model directly, so chatting works without the API server running
@MainActor
class ChatViewModel: ObservableObject {
    @Published var entries: [ChatEntry] = []
    @Published var input: String = ""
    @Published var isResponding: Bool = false
    @Published var selectedModel: AppleModel = .onDevice {
        didSet {
            if oldValue != selectedModel { reset() }
        }
    }

    // One session per conversation keeps multi-turn context
    private var session: LanguageModelSession?
    private var responseTask: Task<Void, Never>?

    func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }

        input = ""
        entries.append(ChatEntry(role: .user, text: prompt))

        let (available, reason) = selectedModel.availability()
        guard available else {
            entries.append(
                ChatEntry(
                    role: .assistant,
                    text: reason ?? "\(selectedModel.displayName) is not available",
                    isError: true))
            return
        }

        let session = self.session ?? selectedModel.makeSession(transcript: Transcript())
        self.session = session

        let reply = ChatEntry(role: .assistant, text: "")
        entries.append(reply)
        isResponding = true

        responseTask = Task {
            do {
                for try await snapshot in session.streamResponse(to: prompt) {
                    update(reply.id) { $0.text = snapshot.content }
                }
            } catch is CancellationError {
                update(reply.id) { if $0.text.isEmpty { $0.text = "(stopped)" } }
            } catch {
                update(reply.id) {
                    $0.text = error.localizedDescription
                    $0.isError = true
                }
            }
            isResponding = false
        }
    }

    func stop() {
        responseTask?.cancel()
    }

    func reset() {
        stop()
        entries = []
        session = nil
        isResponding = false
    }

    private func update(_ id: UUID, _ change: (inout ChatEntry) -> Void) {
        // The conversation may have been reset while a response was streaming
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
    }
}

// MARK: - Main View
struct ChatView: View {
    @StateObject private var chat = ChatViewModel()
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(chat.entries) { entry in
                            ChatBubble(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: chat.entries.last?.text) {
                    if let last = chat.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .overlay {
                if chat.entries.isEmpty {
                    ContentUnavailableView(
                        "Chat with Apple Intelligence",
                        systemImage: "brain.head.profile",
                        description: Text(
                            "Messages go straight to the selected model. The API server doesn't need to be running."
                        )
                    )
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .onSubmit { chat.send() }

                if chat.isResponding {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop generating")
                } else {
                    Button {
                        chat.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (Return)")
                }
            }
            .padding(12)
        }
        .toolbar {
            ToolbarItem {
                Picker("Model", selection: $chat.selectedModel) {
                    ForEach(AppleModel.allCases, id: \.self) { model in
                        Text(
                            model.availability().available
                                ? model.displayName : "\(model.displayName) (unavailable)"
                        )
                        .tag(model)
                    }
                }
                .help("Switching models starts a new chat")
            }
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") {
                    chat.reset()
                }
            }
        }
        .navigationTitle("Chat")
        .onAppear { isInputFocused = true }
    }
}

// MARK: - Helper Views
struct ChatBubble: View {
    let entry: ChatEntry

    var body: some View {
        HStack {
            if entry.role == .user { Spacer(minLength: 60) }

            Group {
                if entry.text.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(entry.text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background)
            .foregroundColor(entry.role == .user ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if entry.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private var background: Color {
        if entry.isError { return Color.red.opacity(0.2) }
        return entry.role == .user ? Color.accentColor : Color.gray.opacity(0.15)
    }
}

#Preview {
    ChatView()
}
