import CoreGraphics
import Foundation
import FoundationModels
import Security
import Vapor

// MARK: - Model Selection

/// Models selectable through the OpenAI `model` field.
///
/// Private Cloud Compute and image input only exist in the macOS 27 SDK (Xcode 27, Swift 6.4),
/// so that code is compiled conditionally to keep Xcode 26 builds working.
nonisolated enum AppleModel: String, CaseIterable, Sendable {
    case onDevice = "apple-on-device"
    case onDeviceContentTagging = "apple-on-device-content-tagging"
    case privateCloudCompute = "apple-private-cloud-compute"

    /// Unknown model ids (e.g. "gpt-4o" from existing clients) fall back to the on-device model
    init(requested: String?) {
        self = requested.flatMap(AppleModel.init(rawValue:)) ?? .onDevice
    }

    var displayName: String {
        switch self {
        case .onDevice: return "On-Device"
        case .onDeviceContentTagging: return "On-Device (Content Tagging)"
        case .privateCloudCompute: return "Private Cloud Compute"
        }
    }

    func availability() -> (available: Bool, reason: String?) {
        switch self {
        case .onDevice:
            return Self.describe(SystemLanguageModel.default.availability)
        case .onDeviceContentTagging:
            return Self.describe(SystemLanguageModel(useCase: .contentTagging).availability)
        case .privateCloudCompute:
            #if compiler(>=6.4)
            guard #available(macOS 27.0, *) else {
                return (false, "Private Cloud Compute requires macOS 27 or later")
            }
            // Without the entitlement every request fails with "Operation not permitted"
            guard Self.hasPrivateCloudComputeEntitlement else {
                return (
                    false,
                    "Requires an app signed with the \(Self.privateCloudComputeEntitlement) entitlement"
                )
            }
            switch PrivateCloudComputeLanguageModel().availability {
            case .available:
                return (true, nil)
            case .unavailable(.deviceNotEligible):
                return (false, "Device not eligible for Private Cloud Compute")
            case .unavailable(.systemNotReady):
                return (false, "Private Cloud Compute is not ready yet. Please try again later.")
            @unknown default:
                return (false, "Unknown Private Cloud Compute availability status")
            }
            #else
            return (false, "Private Cloud Compute requires macOS 27 and an app built with Xcode 27")
            #endif
        }
    }

    /// Image input needs macOS 27 and a model with the vision capability
    var supportsImages: Bool {
        #if compiler(>=6.4)
        guard #available(macOS 27.0, *) else { return false }
        switch self {
        case .onDevice:
            return SystemLanguageModel.default.capabilities.contains(.vision)
        case .onDeviceContentTagging:
            // Reports .vision, but prompts with images fail with "Unable to tokenize prompt"
            return false
        case .privateCloudCompute:
            return PrivateCloudComputeLanguageModel().capabilities.contains(.vision)
        }
        #else
        return false
        #endif
    }

    var imagesUnsupportedReason: String {
        #if compiler(>=6.4)
        guard #available(macOS 27.0, *) else { return "Image input requires macOS 27 or later" }
        return "\(displayName) doesn't support image input"
        #else
        return "Image input requires macOS 27 and an app built with Xcode 27"
        #endif
    }

    private static let privateCloudComputeEntitlement = "com.apple.developer.private-cloud-compute"

    private static var hasPrivateCloudComputeEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task, privateCloudComputeEntitlement as CFString, nil)
        else { return false }
        return (value as? Bool) ?? true
    }

    func makeSession(transcript: Transcript) -> LanguageModelSession {
        switch self {
        case .onDevice:
            return LanguageModelSession(model: .default, transcript: transcript)
        case .onDeviceContentTagging:
            return LanguageModelSession(
                model: SystemLanguageModel(useCase: .contentTagging), transcript: transcript)
        case .privateCloudCompute:
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) {
                return LanguageModelSession(
                    model: PrivateCloudComputeLanguageModel(), transcript: transcript)
            }
            #endif
            // availability() rejects this case before a session is created
            return LanguageModelSession(model: .default, transcript: transcript)
        }
    }

    private static func describe(_ availability: SystemLanguageModel.Availability) -> (
        available: Bool, reason: String?
    ) {
        switch availability {
        case .available:
            return (true, nil)

        case .unavailable(let reason):
            let reasonString: String
            switch reason {
            case .deviceNotEligible:
                reasonString =
                    "Device not eligible for Apple Intelligence. Supported devices: iPhone 15 Pro/Pro Max or newer, iPad with M1 chip or newer, Mac with Apple Silicon"

            case .appleIntelligenceNotEnabled:
                reasonString =
                    "Apple Intelligence not enabled. Enable it in Settings > Apple Intelligence & Siri"

            case .modelNotReady:
                reasonString =
                    "AI model not ready. Models are downloaded automatically based on network status, battery level, and system load. Please wait and try again later."

            @unknown default:
                reasonString = "Unknown availability issue"
            }
            return (false, reasonString)

        @unknown default:
            return (false, "Unknown availability status")
        }
    }
}

// MARK: - Apple Intelligence Manager

/// Manager for Apple Intelligence on-device language model
actor OnDeviceModelManager {
    private let model: SystemLanguageModel

    init() {
        self.model = SystemLanguageModel.default
    }

    /// Check if the on-device model is available
    func isModelAvailable() -> (available: Bool, reason: String?) {
        AppleModel.onDevice.availability()
    }

    /// Get supported languages
    func getSupportedLanguages() -> [String] {
        let languages = model.supportedLanguages

        return languages.compactMap { language -> String? in
            let locale = Locale(identifier: language.maximalIdentifier)

            // Get the display name in the current locale
            if let displayName = locale.localizedString(forIdentifier: language.maximalIdentifier) {
                return displayName
            }

            // Fallback to language code if display name is not available
            return language.languageCode?.identifier
        }.sorted()
    }

    /// Convert chat messages to transcript entries.
    ///
    /// The framework expects at most one instructions entry, placed first in the
    /// transcript, so all system/developer messages are merged into it.
    nonisolated func convertMessagesToTranscript(_ messages: [ChatMessage]) async throws
        -> [Transcript.Entry]
    {
        var instructionTexts: [String] = []
        var entries: [Transcript.Entry] = []

        for message in messages where !message.isEmpty {
            switch message.role.lowercased() {
            case "system", "developer":
                if !message.content.isEmpty {
                    instructionTexts.append(message.content)
                }

            case "assistant":
                let segments: [Transcript.Segment] = [
                    .text(Transcript.TextSegment(content: message.content))
                ]
                entries.append(.response(Transcript.Response(assetIDs: [], segments: segments)))

            default:
                // user, tool and unknown roles are treated as user prompts
                let segments = try await promptSegments(for: message)
                entries.append(.prompt(Transcript.Prompt(segments: segments)))
            }
        }

        if !instructionTexts.isEmpty {
            let instructions = Transcript.Instructions(
                segments: [
                    .text(Transcript.TextSegment(content: instructionTexts.joined(separator: "\n\n")))
                ],
                toolDefinitions: []
            )
            entries.insert(.instructions(instructions), at: 0)
        }

        return entries
    }

    /// Transcript segments for a user message's text and images
    private nonisolated func promptSegments(for message: ChatMessage) async throws
        -> [Transcript.Segment]
    {
        var segments: [Transcript.Segment] = []
        if !message.content.isEmpty {
            segments.append(.text(Transcript.TextSegment(content: message.content)))
        }
        guard !message.imageURLs.isEmpty else { return segments }

        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            for url in message.imageURLs {
                let image = try await ImageLoader.loadImage(from: url)
                let attachment = Transcript.AttachmentSegment(
                    content: .image(Transcript.ImageAttachment(image)))
                segments.append(.attachment(attachment))
            }
            return segments
        }
        #endif
        throw Abort(.badRequest, reason: AppleModel.onDevice.imagesUnsupportedReason)
    }

    /// Build the prompt for the last message, attaching its images
    private nonisolated func makePrompt(for message: ChatMessage) async throws
        -> FoundationModels.Prompt
    {
        guard !message.imageURLs.isEmpty else {
            return FoundationModels.Prompt(message.content)
        }

        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            var images: [CGImage] = []
            for url in message.imageURLs {
                images.append(try await ImageLoader.loadImage(from: url))
            }
            let text = message.content
            return FoundationModels.Prompt {
                if !text.isEmpty {
                    text
                }
                for image in images {
                    FoundationModels.Attachment(image)
                }
            }
        }
        #endif
        throw Abort(.badRequest, reason: AppleModel.onDevice.imagesUnsupportedReason)
    }

    /// Build a session holding the conversation history and return it with the prompt to send.
    ///
    /// The last message becomes the prompt; everything before it becomes the transcript.
    nonisolated func prepareSession(for messages: [ChatMessage], model appleModel: AppleModel)
        async throws -> (session: LanguageModelSession, prompt: FoundationModels.Prompt)
    {
        let (available, reason) = appleModel.availability()
        guard available else {
            throw Abort(
                .serviceUnavailable, reason: reason ?? "\(appleModel.displayName) is not available")
        }
        guard let lastMessage = messages.last else {
            throw Abort(.badRequest, reason: "No messages provided")
        }
        guard !lastMessage.isEmpty else {
            throw Abort(.badRequest, reason: "The last message must have text or image content")
        }
        if messages.contains(where: { !$0.imageURLs.isEmpty }) && !appleModel.supportsImages {
            throw Abort(.badRequest, reason: appleModel.imagesUnsupportedReason)
        }

        let transcript = Transcript(
            entries: try await convertMessagesToTranscript(Array(messages.dropLast())))
        let session = appleModel.makeSession(transcript: transcript)
        return (session, try await makePrompt(for: lastMessage))
    }

    /// Build generation options from OpenAI request parameters
    nonisolated func makeOptions(temperature: Double?, maxTokens: Int?) -> GenerationOptions {
        GenerationOptions(temperature: temperature, maximumResponseTokens: maxTokens)
    }

    /// Generate a response for the given messages with conversation context
    func generateResponse(
        for messages: [ChatMessage], model appleModel: AppleModel = .onDevice,
        temperature: Double? = nil, maxTokens: Int? = nil
    ) async throws -> String {
        let (session, prompt) = try await prepareSession(for: messages, model: appleModel)
        let options = makeOptions(temperature: temperature, maxTokens: maxTokens)

        do {
            let response = try await session.respond(to: prompt, options: options)
            return response.content
        } catch {
            throw GenerationFailure(error)
        }
    }
}

// MARK: - Error Mapping

/// A FoundationModels generation error translated to an OpenAI-style HTTP error.
///
/// macOS 26 throws `LanguageModelSession.GenerationError`. macOS 27 deprecates it and
/// throws `LanguageModelError` instead, which only exists in the macOS 27 SDK (Xcode 27,
/// Swift 6.4), so that branch is compiled conditionally to keep Xcode 26 builds working.
nonisolated struct GenerationFailure: AbortError {
    let status: HTTPResponseStatus
    let reason: String
    /// OpenAI error `type`
    let errorType: String
    /// OpenAI error `code`
    let code: String?

    init(_ error: any Error) {
        if let failure = error as? GenerationFailure {
            self = failure
            return
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        if let abort = error as? any AbortError {
            self.init(
                abort.status, abort.reason,
                errorType: abort.status == .serviceUnavailable
                    ? "unavailable_error" : "invalid_request_error",
                code: nil)
            return
        }

        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                self.init(
                    .badRequest, message, errorType: "invalid_request_error",
                    code: "context_length_exceeded")
            case .rateLimited:
                self.init(
                    .tooManyRequests, message, errorType: "rate_limit_error",
                    code: "rate_limit_exceeded")
            case .guardrailViolation:
                self.init(
                    .badRequest, message, errorType: "invalid_request_error", code: "content_filter")
            case .refusal:
                self.init(.badRequest, message, errorType: "invalid_request_error", code: "refusal")
            case .timeout:
                self.init(.gatewayTimeout, message, errorType: "timeout_error", code: "timeout")
            case .unsupportedLanguageOrLocale:
                self.init(
                    .badRequest, message, errorType: "invalid_request_error",
                    code: "unsupported_language")
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
                self.init(
                    .badRequest, message, errorType: "invalid_request_error",
                    code: "unsupported_request")
            @unknown default:
                self.init(.internalServerError, message, errorType: "internal_error", code: nil)
            }
            return
        }

        if #available(macOS 27.0, *), let error = error as? PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .quotaLimitReached:
                self.init(
                    .tooManyRequests, message, errorType: "rate_limit_error",
                    code: "quota_limit_reached")
            case .networkFailure, .serviceUnavailable:
                self.init(.serviceUnavailable, message, errorType: "unavailable_error", code: nil)
            @unknown default:
                self.init(.internalServerError, message, errorType: "internal_error", code: nil)
            }
            return
        }
        #endif

        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                self.init(
                    .badRequest, message, errorType: "invalid_request_error",
                    code: "context_length_exceeded")
            case .rateLimited:
                self.init(
                    .tooManyRequests, message, errorType: "rate_limit_error",
                    code: "rate_limit_exceeded")
            case .concurrentRequests:
                self.init(
                    .tooManyRequests, message, errorType: "rate_limit_error",
                    code: "concurrent_requests")
            case .guardrailViolation:
                self.init(
                    .badRequest, message, errorType: "invalid_request_error", code: "content_filter")
            case .refusal:
                self.init(.badRequest, message, errorType: "invalid_request_error", code: "refusal")
            case .unsupportedLanguageOrLocale:
                self.init(
                    .badRequest, message, errorType: "invalid_request_error",
                    code: "unsupported_language")
            case .unsupportedGuide:
                self.init(
                    .badRequest, message, errorType: "invalid_request_error",
                    code: "unsupported_request")
            case .assetsUnavailable:
                self.init(
                    .serviceUnavailable, message, errorType: "unavailable_error",
                    code: "model_not_ready")
            case .decodingFailure:
                self.init(.internalServerError, message, errorType: "internal_error", code: nil)
            @unknown default:
                self.init(.internalServerError, message, errorType: "internal_error", code: nil)
            }
            return
        }

        self.init(
            .internalServerError,
            "Error generating response: \(message)",
            errorType: "internal_error", code: nil)
    }

    private init(_ status: HTTPResponseStatus, _ reason: String, errorType: String, code: String?) {
        self.status = status
        self.reason = reason
        self.errorType = errorType
        self.code = code
    }

    var errorResponse: ErrorResponse {
        ErrorResponse(error: ErrorDetail(message: reason, type: errorType, param: nil, code: code))
    }
}

// Global instance of the Apple Intelligence manager
let aiManager = OnDeviceModelManager()
