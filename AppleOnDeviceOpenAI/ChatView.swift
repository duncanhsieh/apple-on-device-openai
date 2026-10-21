//
//  ChatView.swift
//  AppleOnDeviceOpenAI
//

import Combine
import FoundationModels
import SwiftUI
import UniformTypeIdentifiers

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
    var images: [ChatImage] = []
    var isError = false
}

struct ChatImage: Identifiable {
    let id = UUID()
    let cgImage: CGImage
}

// MARK: - ViewModel
/// Talks to the selected model directly, so chatting works without the API server running
@MainActor
class ChatViewModel: ObservableObject {
    @Published var entries: [ChatEntry] = []
    @Published var input: String = ""
    @Published var isResponding: Bool = false
    @Published var pendingImages: [ChatImage] = []
    @Published var isLoadingImage: Bool = false
    @Published var attachmentError: String?
    @Published var selectedModel: AppleModel = .onDevice {
        didSet {
            if oldValue != selectedModel { reset() }
        }
    }

    var supportsImages: Bool {
        selectedModel.supportsImages
    }

    // One session per conversation keeps multi-turn context
    private var session: LanguageModelSession?
    private var responseTask: Task<Void, Never>?

    var canSend: Bool {
        !isResponding && !isLoadingImage
            && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingImages.isEmpty)
    }

    func send() {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }

        let images = pendingImages
        input = ""
        pendingImages = []
        attachmentError = nil
        entries.append(ChatEntry(role: .user, text: prompt, images: images))

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
                for try await snapshot in stream(session, prompt: prompt, images: images) {
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
        pendingImages = []
        attachmentError = nil
        session = nil
        isResponding = false
    }

    // MARK: Images

    func addImage(fromFile url: URL) {
        // Files from the open panel or a drop are security-scoped in the sandbox
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            pendingImages.append(ChatImage(cgImage: try ImageLoader.decodeImage(data)))
            attachmentError = nil
        } catch {
            attachmentError = ImageLoader.message(for: error)
        }
    }

    /// Load an image from a pasted http(s) or data URL (same rules as the API's `image_url`)
    func addImage(fromURLString string: String) {
        let urlString = string.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoadingImage = true
        attachmentError = nil
        Task {
            do {
                let image = try await ImageLoader.loadImage(from: urlString)
                pendingImages.append(ChatImage(cgImage: image))
            } catch {
                attachmentError = ImageLoader.message(for: error)
            }
            isLoadingImage = false
        }
    }

    /// Handle URLs dropped onto the chat: local image files or web image links
    func addDroppedImages(_ urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                addImage(fromFile: url)
            } else {
                addImage(fromURLString: url.absoluteString)
            }
        }
    }

    func removePendingImage(_ id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    private func stream(_ session: LanguageModelSession, prompt: String, images: [ChatImage])
        -> LanguageModelSession.ResponseStream<String>
    {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), !images.isEmpty {
            return session.streamResponse {
                prompt
                for image in images {
                    Attachment(image.cgImage)
                }
            }
        }
        #endif
        return session.streamResponse(to: prompt)
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
    @State private var isImporterPresented = false
    @State private var isURLPromptPresented = false
    @State private var imageURLInput = ""

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

            if !chat.pendingImages.isEmpty || chat.isLoadingImage || chat.attachmentError != nil {
                AttachmentTray(chat: chat)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("Choose Image…", systemImage: "photo") {
                        isImporterPresented = true
                    }
                    Button("Image from URL…", systemImage: "link") {
                        imageURLInput = ""
                        isURLPromptPresented = true
                    }
                } label: {
                    Image(systemName: "paperclip")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(!chat.supportsImages || chat.isResponding)
                .help(
                    chat.supportsImages
                        ? "Attach an image (or drop one onto the chat)"
                        : chat.selectedModel.imagesUnsupportedReason)

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
                    .disabled(!chat.canSend)
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
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                urls.forEach(chat.addImage(fromFile:))
            case .failure(let error):
                chat.attachmentError = error.localizedDescription
            }
        }
        .alert("Image from URL", isPresented: $isURLPromptPresented) {
            TextField("https://example.com/image.jpg", text: $imageURLInput)
            Button("Add") {
                chat.addImage(fromURLString: imageURLInput)
            }
            Button("Cancel", role: .cancel) {}
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard chat.supportsImages, !chat.isResponding else { return false }
            chat.addDroppedImages(urls)
            return true
        }
    }
}

// MARK: - Helper Views
struct AttachmentTray: View {
    @ObservedObject var chat: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chat.pendingImages) { image in
                        ZStack(alignment: .topTrailing) {
                            ChatThumbnail(image: image, size: 64)

                            Button {
                                chat.removePendingImage(image.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.borderless)
                            .padding(2)
                            .help("Remove image")
                        }
                    }

                    if chat.isLoadingImage {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 64, height: 64)
                    }
                }
            }

            if let error = chat.attachmentError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}

struct ChatThumbnail: View {
    let image: ChatImage
    let size: CGFloat

    var body: some View {
        Image(decorative: image.cgImage, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ChatBubble: View {
    let entry: ChatEntry

    var body: some View {
        HStack {
            if entry.role == .user { Spacer(minLength: 60) }

            VStack(alignment: entry.role == .user ? .trailing : .leading, spacing: 6) {
                if !entry.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(entry.images) { image in
                            ChatThumbnail(image: image, size: 120)
                        }
                    }
                }

                if !entry.text.isEmpty || entry.images.isEmpty {
                    bubble
                }
            }

            if entry.role == .assistant { Spacer(minLength: 60) }
        }
    }

    private var bubble: some View {
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
    }

    private var background: Color {
        if entry.isError { return Color.red.opacity(0.2) }
        return entry.role == .user ? Color.accentColor : Color.gray.opacity(0.15)
    }
}

#Preview {
    ChatView()
}
