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
    @State private var isDropTargeted = false

    /// Height of one composer line; the attach button, field and send button all share it
    private static let composerRowHeight: CGFloat = 28

    private static let suggestions = [
        "Write a haiku about autumn in Taipei",
        "Explain recursion to a ten-year-old",
        "Give me three name ideas for a coffee shop",
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(chat.entries) { entry in
                        ChatBubble(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.entries.last?.text) {
                if let last = chat.entries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .overlay {
            if chat.entries.isEmpty {
                emptyState
            }
        }
        .overlay {
            if isDropTargeted {
                DropHighlight()
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            composer
        }
        .frame(minWidth: 420, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Model", selection: $chat.selectedModel) {
                        ForEach(AppleModel.allCases, id: \.self) { model in
                            Text(model.displayName)
                                .tag(model)
                                .selectionDisabled(!model.availability().available)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 6) {
                        Text(chat.selectedModel.displayName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Model (switching starts a new chat)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Chat", systemImage: "square.and.pencil") {
                    chat.reset()
                    isInputFocused = true
                }
                .keyboardShortcut("n")
                .disabled(chat.entries.isEmpty)
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
        .alert("Add Image from URL", isPresented: $isURLPromptPresented) {
            TextField("https://example.com/image.jpg", text: $imageURLInput)
            Button("Add") {
                chat.addImage(fromURLString: imageURLInput)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the address of a PNG, JPEG, HEIC or other image.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard chat.supportsImages, !chat.isResponding else { return false }
            chat.addDroppedImages(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted && chat.supportsImages
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Chat with Apple Intelligence", systemImage: "brain.head.profile")
        } description: {
            Text("Messages go straight to the model on this Mac. The API server doesn't need to be running.")
        } actions: {
            VStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) {
                        chat.input = suggestion
                        chat.send()
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !chat.pendingImages.isEmpty || chat.isLoadingImage || chat.attachmentError != nil {
                AttachmentTray(chat: chat)
            }

            HStack(alignment: .bottom, spacing: 6) {
                if chat.supportsImages {
                    Menu {
                        Button("Choose Image…", systemImage: "photo") {
                            isImporterPresented = true
                        }
                        Button("Add Image from URL…", systemImage: "link") {
                            imageURLInput = ""
                            isURLPromptPresented = true
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    // Menu ignores its label's frame, so size the menu itself to the row
                    .frame(width: Self.composerRowHeight, height: Self.composerRowHeight)
                    .disabled(chat.isResponding)
                    .help("Attach an image, or drop one onto the chat")
                }

                TextField("Message", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isInputFocused)
                    .onSubmit { chat.send() }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .frame(minHeight: Self.composerRowHeight)

                if chat.isResponding {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 22))
                            .frame(width: Self.composerRowHeight, height: Self.composerRowHeight)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop responding")
                } else {
                    Button {
                        chat.send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(chat.canSend ? Color.accentColor : Color.secondary)
                            .frame(width: Self.composerRowHeight, height: Self.composerRowHeight)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!chat.canSend)
                    .help("Send")
                }
            }
            .padding(.leading, chat.supportsImages ? 4 : 10)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.separator)
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

// MARK: - Helper Views
struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay {
                Label("Drop images to attach", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}

struct AttachmentTray: View {
    @ObservedObject var chat: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chat.pendingImages) { image in
                        ChatThumbnail(image: image, size: 56)
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    chat.removePendingImage(image.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .buttonStyle(.borderless)
                                .padding(3)
                                .help("Remove")
                            }
                    }

                    if chat.isLoadingImage {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: 56, height: 56)
                            .overlay { ProgressView().controlSize(.small) }
                    }
                }
            }

            if let error = chat.attachmentError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
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
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator)
            )
    }
}

struct ChatBubble: View {
    let entry: ChatEntry

    private var isUser: Bool { entry.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if !entry.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.images) { image in
                        ChatThumbnail(image: image, size: 140)
                    }
                }
            }

            if !entry.text.isEmpty || entry.images.isEmpty {
                bubble
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(isUser ? .leading : .trailing, 60)
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if entry.text.isEmpty {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .foregroundStyle(.secondary)
                    .frame(height: 18)
            } else if entry.isError {
                Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Text(entry.text)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(isUser ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(background)
        )
    }

    private var background: AnyShapeStyle {
        if entry.isError { return AnyShapeStyle(Color.red.opacity(0.12)) }
        if isUser { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(.quaternary)
    }
}

#Preview {
    ChatView()
}
