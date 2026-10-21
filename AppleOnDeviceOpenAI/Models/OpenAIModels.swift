import Foundation
import FoundationModels
import Vapor

// MARK: - Data Models

// Define a simple structure for the AI response using @Generable
@Generable
nonisolated struct AIResponse: Sendable {
    let answer: String
    let confidence: String
}

// MARK: - Request Models

nonisolated struct ChatCompletionRequest: Content, Sendable {
    let model: String?
    let messages: [ChatMessage]
    let maxTokens: Int?
    let maxCompletionTokens: Int?
    let temperature: Double?
    let topP: Double?
    let n: Int?
    let stream: Bool?
    let stop: [String]?
    let presencePenalty: Double?
    let frequencyPenalty: Double?
    let logitBias: [String: Double]?
    let user: String?
    let responseFormat: ResponseFormat?

    /// `max_completion_tokens` replaces the deprecated `max_tokens` in current OpenAI clients
    var responseTokenLimit: Int? { maxCompletionTokens ?? maxTokens }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case temperature
        case topP = "top_p"
        case n
        case stream
        case stop
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case logitBias = "logit_bias"
        case user
        case responseFormat = "response_format"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.messages = try container.decode([ChatMessage].self, forKey: .messages)
        self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        self.maxCompletionTokens = try container.decodeIfPresent(
            Int.self, forKey: .maxCompletionTokens)
        self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        self.topP = try container.decodeIfPresent(Double.self, forKey: .topP)
        self.n = try container.decodeIfPresent(Int.self, forKey: .n)
        self.stream = try container.decodeIfPresent(Bool.self, forKey: .stream)
        // `stop` may be a single string or an array of strings
        if let single = try? container.decodeIfPresent(String.self, forKey: .stop) {
            self.stop = [single]
        } else {
            self.stop = try container.decodeIfPresent([String].self, forKey: .stop)
        }
        self.presencePenalty = try container.decodeIfPresent(Double.self, forKey: .presencePenalty)
        self.frequencyPenalty = try container.decodeIfPresent(
            Double.self, forKey: .frequencyPenalty)
        self.logitBias = try container.decodeIfPresent([String: Double].self, forKey: .logitBias)
        self.user = try container.decodeIfPresent(String.self, forKey: .user)
        self.responseFormat = try container.decodeIfPresent(
            ResponseFormat.self, forKey: .responseFormat)
    }
}

/// OpenAI `response_format`: `text`, `json_schema` (structured output) or `json_object`
nonisolated struct ResponseFormat: Content, Sendable {
    let type: String
    let jsonSchema: JSONSchemaFormat?

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

nonisolated struct JSONSchemaFormat: Content, Sendable {
    let name: String?
    let description: String?
    let schema: JSONValue?
    let strict: Bool?
}

/// Any JSON value, used to carry JSON Schemas through Codable
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }

    var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// Content types for structured messages
nonisolated struct MessageContent: Content, Sendable {
    let type: String
    let text: String?
    let imageUrl: ImageUrl?
    
    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageUrl = "image_url"
    }
}

nonisolated struct ImageUrl: Content, Sendable {
    let url: String
    let detail: String?
}

nonisolated struct ChatMessage: Content, Sendable {
    let role: String
    let content: String
    let name: String?
    /// URLs from `image_url` content parts (data URLs or http(s) URLs)
    let imageURLs: [String]

    init(role: String, content: String, name: String? = nil, imageURLs: [String] = []) {
        self.role = role
        self.content = content
        self.name = name
        self.imageURLs = imageURLs
    }
    
    // Custom decoder to handle both string and array content formats
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        self.role = try container.decode(String.self, forKey: .role)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        
        // Try to decode content as string first
        if try !container.contains(.content) || container.decodeNil(forKey: .content) {
            // Assistant messages that only carry tool calls have null content
            self.content = ""
            self.imageURLs = []
        } else if let stringContent = try? container.decode(String.self, forKey: .content) {
            self.content = stringContent
            self.imageURLs = []
        } else if let arrayContent = try? container.decode([MessageContent].self, forKey: .content) {
            // Extract text and images from structured content array
            let textParts = arrayContent.compactMap { contentItem in
                contentItem.type == "text" ? contentItem.text : nil
            }
            self.content = textParts.joined(separator: " ")
            self.imageURLs = arrayContent.compactMap { contentItem in
                contentItem.type == "image_url" ? contentItem.imageUrl?.url : nil
            }
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath + [CodingKeys.content],
                    debugDescription: "Content must be either a string or an array of content objects"
                )
            )
        }
    }
    
    /// True when the message has neither text nor images
    var isEmpty: Bool { content.isEmpty && imageURLs.isEmpty }

    // Custom encoder to always encode as string
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(name, forKey: .name)
    }
    
    enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
    }
}

// MARK: - Response Models

nonisolated struct ChatCompletionResponse: Content, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [ChatCompletionChoice]

    init(id: String, object: String, created: Int, model: String, choices: [ChatCompletionChoice]) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
    }
}

nonisolated struct ChatCompletionChoice: Content, Sendable {
    let index: Int
    let message: ChatMessage?
    let delta: ChatMessage?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case delta
        case finishReason = "finish_reason"
    }

    init(
        index: Int, message: ChatMessage? = nil, delta: ChatMessage? = nil,
        finishReason: String? = nil
    ) {
        self.index = index
        self.message = message
        self.delta = delta
        self.finishReason = finishReason
    }
}

// MARK: - Models List Response

nonisolated struct ModelsResponse: Content, Sendable {
    let object: String
    let data: [ModelInfo]
}

nonisolated struct ModelInfo: Content, Sendable {
    let id: String
    let object: String
    let created: Int
    let ownedBy: String

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
    }
}

// MARK: - Server Status Response

nonisolated struct ServerStatus: Content, Sendable {
    let modelAvailable: Bool
    let reason: String
    let supportedLanguages: [String]
    let serverVersion: String
    let appleIntelligenceCompatible: Bool
    /// Whether the default on-device model accepts `image_url` parts
    let imageInputSupported: Bool
    let models: [ModelStatus]

    enum CodingKeys: String, CodingKey {
        case modelAvailable = "model_available"
        case reason
        case supportedLanguages = "supported_languages"
        case serverVersion = "server_version"
        case appleIntelligenceCompatible = "apple_intelligence_compatible"
        case imageInputSupported = "image_input_supported"
        case models
    }
}

nonisolated struct ModelStatus: Content, Sendable {
    let id: String
    let available: Bool
    let reason: String?
    let imageInput: Bool

    init(id: String, available: Bool, reason: String?, imageInput: Bool = false) {
        self.id = id
        self.available = available
        self.reason = reason
        self.imageInput = imageInput
    }

    enum CodingKeys: String, CodingKey {
        case id
        case available
        case reason
        case imageInput = "image_input"
    }
}

// MARK: - Error Response

nonisolated struct ErrorResponse: Content, Sendable {
    let error: ErrorDetail
}

nonisolated struct ErrorDetail: Content, Sendable {
    let message: String
    let type: String
    let param: String?
    let code: String?
}

// MARK: - Streaming Response Models

nonisolated struct ChatCompletionStreamResponse: Content, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [ChatCompletionStreamChoice]

    init(
        id: String, object: String, created: Int, model: String,
        choices: [ChatCompletionStreamChoice]
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
    }
}

nonisolated struct ChatCompletionStreamChoice: Content, Sendable {
    let index: Int
    let delta: ChatCompletionDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case delta
        case finishReason = "finish_reason"
    }

    init(index: Int, delta: ChatCompletionDelta, finishReason: String? = nil) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
    }
}

nonisolated struct ChatCompletionDelta: Content, Sendable {
    let role: String?
    let content: String?

    init(role: String? = nil, content: String? = nil) {
        self.role = role
        self.content = content
    }
}
