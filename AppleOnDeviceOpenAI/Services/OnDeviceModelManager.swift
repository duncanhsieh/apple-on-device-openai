import Foundation
import FoundationModels
import Vapor

// MARK: - Model Selection

/// Models selectable through the OpenAI `model` field
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
            guard #available(macOS 27.0, *) else {
                return (false, "Private Cloud Compute requires macOS 27 or later")
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
        }
    }

    /// Image input needs macOS 27 and a model with the vision capability
    var supportsImages: Bool {
        guard #available(macOS 27.0, *) else { return false }
        switch self {
        case .onDevice:
            return SystemLanguageModel.default.capabilities.contains(.vision)
        case .onDeviceContentTagging:
            return SystemLanguageModel(useCase: .contentTagging).capabilities.contains(.vision)
        case .privateCloudCompute:
            return PrivateCloudComputeLanguageModel().capabilities.contains(.vision)
        }
    }

    var imagesUnsupportedReason: String {
        guard #available(macOS 27.0, *) else { return "Image input requires macOS 27 or later" }
        return "\(displayName) doesn't support image input"
    }

    func makeSession(transcript: Transcript) -> LanguageModelSession {
        switch self {
        case .onDevice:
            return LanguageModelSession(model: .default, transcript: transcript)
        case .onDeviceContentTagging:
            return LanguageModelSession(
                model: SystemLanguageModel(useCase: .contentTagging), transcript: transcript)
        case .privateCloudCompute:
            guard #available(macOS 27.0, *) else {
                // availability() rejects this case before a session is created
                return LanguageModelSession(model: .default, transcript: transcript)
            }
            return LanguageModelSession(
                model: PrivateCloudComputeLanguageModel(), transcript: transcript)
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

    /// Convert chat messages to transcript entries
    func convertMessagesToTranscript(_ messages: [ChatMessage]) -> [Transcript.Entry] {
        var entries: [Transcript.Entry] = []

        // Process all messages in order
        for message in messages {
            let textSegment = Transcript.TextSegment(content: message.content)

            switch message.role.lowercased() {
            case "system":
                // Convert system messages to instructions
                let instructions = Transcript.Instructions(
                    segments: [.text(textSegment)],
                    toolDefinitions: []
                )
                entries.append(.instructions(instructions))

            case "user":
                // Convert user messages to prompts
                let prompt = Transcript.Prompt(
                    segments: [.text(textSegment)]
                )
                entries.append(.prompt(prompt))

            case "assistant":
                // Convert assistant messages to responses
                let response = Transcript.Response(
                    assetIDs: [],
                    segments: [.text(textSegment)]
                )
                entries.append(.response(response))

            default:
                // Treat unknown roles as user messages
                let prompt = Transcript.Prompt(
                    segments: [.text(textSegment)]
                )
                entries.append(.prompt(prompt))
            }
        }

        return entries
    }

    /// Generate a response for the given messages with conversation context
    func generateResponse(
        for messages: [ChatMessage], model appleModel: AppleModel = .onDevice,
        temperature: Double? = nil, maxTokens: Int? = nil
    ) async throws -> String {
        // Check availability first
        let (available, reason) = appleModel.availability()
        guard available else {
            throw Abort(
                .serviceUnavailable, reason: reason ?? "\(appleModel.displayName) is not available")
        }

        guard !messages.isEmpty else {
            throw Abort(.badRequest, reason: "No messages provided")
        }

        // Get the last message as the current prompt
        let lastMessage = messages.last!
        let currentPrompt = lastMessage.content

        // Convert previous messages (excluding the last one) to transcript
        let previousMessages = messages.count > 1 ? Array(messages.dropLast()) : []
        let transcriptEntries = convertMessagesToTranscript(previousMessages)

        // Create transcript with conversation history
        let transcript = Transcript(entries: transcriptEntries)

        // Create new session with the conversation transcript
        let session = appleModel.makeSession(transcript: transcript)

        do {
            // Create generation options if temperature is specified
            var options = GenerationOptions()
            if let temp = temperature {
                options = GenerationOptions(temperature: temp, maximumResponseTokens: maxTokens)
            } else if let maxTokens = maxTokens {
                options = GenerationOptions(maximumResponseTokens: maxTokens)
            }

            // Generate response using the current prompt
            let response = try await session.respond(
                to: currentPrompt,
                options: options
            )

            let content = response.content
            return content
        } catch {
            throw Abort(
                Self.httpStatus(for: error),
                reason: "Error generating response: \(error.localizedDescription)")
        }
    }

    /// Map rate limit / quota errors to 429 so OpenAI clients back off and retry
    nonisolated static func httpStatus(for error: Error) -> HTTPResponseStatus {
        if let error = error as? LanguageModelSession.GenerationError,
            case .rateLimited = error
        {
            return .tooManyRequests
        }
        if #available(macOS 27.0, *) {
            if let error = error as? LanguageModelError, case .rateLimited = error {
                return .tooManyRequests
            }
            if let error = error as? PrivateCloudComputeLanguageModel.Error,
                case .quotaLimitReached = error
            {
                return .tooManyRequests
            }
        }
        return .internalServerError
    }

    /// Generate a response for a single prompt (for backward compatibility)
    func generateResponse(for prompt: String, temperature: Double? = nil, maxTokens: Int? = nil)
        async throws -> String
    {
        let messages = [ChatMessage(role: "user", content: prompt)]
        return try await generateResponse(
            for: messages, temperature: temperature, maxTokens: maxTokens)
    }
}

// Global instance of the Apple Intelligence manager
let aiManager = OnDeviceModelManager()
