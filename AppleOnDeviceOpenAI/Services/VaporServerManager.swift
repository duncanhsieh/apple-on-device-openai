//
//  VaporServerManager.swift
//  AppleOnDeviceOpenAI
//
//  Created by Channing Dai on 6/15/25.
//

import Combine
import Foundation
import FoundationModels
import Vapor

@MainActor
class VaporServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var lastError: String?

    private var app: Application?
    private var serverTask: Task<Void, Never>?

    private static var loggingBootstrapped = false

    func startServer(configuration: ServerConfiguration) async {
        guard !isRunning else { return }

        do {
            // Create Vapor application
            var env = try Environment.detect()

            // Only bootstrap logging system once per process
            // This prevents the "logging system can only be initialized once per process" error
            // when stopping and restarting the server
            if !Self.loggingBootstrapped {
                try LoggingSystem.bootstrap(from: &env)
                Self.loggingBootstrapped = true
            }

            let app = Application(env)
            self.app = app

            // Fix for running Vapor in iOS/macOS app - clear command line arguments
            app.environment.arguments = [app.environment.arguments[0]]

            // Vapor's 16 KB default rejects base64 image_url payloads; base64 adds a third,
            // so this fits a couple of images at ImageLoader's 20 MB limit
            app.routes.defaultMaxBodySize = "64mb"

            // Configure routes
            configureRoutes(app)

            // Configure server
            app.http.server.configuration.hostname = configuration.host
            app.http.server.configuration.port = configuration.port

            // Start server in background task
            serverTask = Task {
                do {
                    try await app.execute()
                } catch {
                    await MainActor.run {
                        self.lastError = error.localizedDescription
                        self.isRunning = false
                    }
                }
            }

            isRunning = true
            lastError = nil

        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopServer() async {
        guard isRunning else { return }

        // Cancel the server task
        serverTask?.cancel()
        serverTask = nil

        // Shutdown the application
        if let app = app {
            try? await app.asyncShutdown()
            self.app = nil
        }

        isRunning = false
    }

    private func configureRoutes(_ app: Application) {
        // Health check endpoint
        app.get("health") { req async -> HTTPStatus in
            return .ok
        }

        // Model status endpoint
        app.get("status") { req async throws -> ServerStatus in
            let (available, reason) = await aiManager.isModelAvailable()
            let supportedLanguages = await aiManager.getSupportedLanguages()

            let models = AppleModel.allCases.map { model in
                let (modelAvailable, modelReason) = model.availability()
                return ModelStatus(
                    id: model.rawValue, available: modelAvailable, reason: modelReason,
                    imageInput: model.supportsImages)
            }

            return ServerStatus(
                modelAvailable: available,
                reason: reason ?? "Model is available",
                supportedLanguages: supportedLanguages,
                serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "unknown",
                appleIntelligenceCompatible: true,
                imageInputSupported: AppleModel.onDevice.supportsImages,
                models: models
            )
        }

        // OpenAI compatible endpoints
        let v1 = app.grouped("v1")

        // List models endpoint
        v1.get("models") { req async throws -> ModelsResponse in
            let created = Int(Date().timeIntervalSince1970)
            let models = AppleModel.allCases
                .filter { $0.availability().available }
                .map { model in
                    ModelInfo(
                        id: model.rawValue,
                        object: "model",
                        created: created,
                        ownedBy: "apple-on-device-openai"
                    )
                }

            return ModelsResponse(
                object: "list",
                data: models
            )
        }

        // Chat completions endpoint (main endpoint)
        v1.post("chat", "completions") { req async throws -> Response in
            let chatRequest = try req.content.decode(ChatCompletionRequest.self)

            // Validate request
            guard !chatRequest.messages.isEmpty else {
                throw Abort(.badRequest, reason: "No messages provided")
            }

            let appleModel = AppleModel(requested: chatRequest.model)

            // Reject an unusable response_format up front, before any streaming starts
            let output: StructuredOutput?
            do {
                output = try chatRequest.responseFormat?.structuredOutput(for: appleModel)
            } catch {
                let failure = GenerationFailure(error)
                return try Self.jsonResponse(failure.errorResponse, status: failure.status)
            }

            if chatRequest.stream == true {
                return Self.makeStreamingResponse(chatRequest, model: appleModel, output: output)
            }

            do {
                let response = try await aiManager.generateResponse(
                    for: chatRequest.messages,
                    model: appleModel,
                    temperature: chatRequest.temperature,
                    maxTokens: chatRequest.responseTokenLimit,
                    output: output
                )

                let chatResponse = ChatCompletionResponse(
                    id: "chatcmpl-\(UUID().uuidString)",
                    object: "chat.completion",
                    created: Int(Date().timeIntervalSince1970),
                    model: appleModel.rawValue,
                    choices: [
                        ChatCompletionChoice(
                            index: 0,
                            message: ChatMessage(
                                role: "assistant",
                                content: response
                            ),
                            finishReason: "stop"
                        )
                    ]
                )

                return try Self.jsonResponse(chatResponse)
            } catch {
                let failure = GenerationFailure(error)
                return try Self.jsonResponse(failure.errorResponse, status: failure.status)
            }
        }
    }

    private nonisolated static func jsonResponse(
        _ value: some Encodable, status: HTTPResponseStatus = .ok
    ) throws -> Response {
        let response = Response(status: status)
        response.headers.contentType = .json
        response.body = .init(data: try JSONEncoder().encode(value))
        return response
    }

    private nonisolated static func sseEvent(_ value: some Encodable) throws -> ByteBuffer {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return ByteBuffer(string: "data: \(json)\n\n")
    }

    // Helper function to handle streaming responses
    private nonisolated static func makeStreamingResponse(
        _ chatRequest: ChatCompletionRequest, model appleModel: AppleModel,
        output: StructuredOutput?
    ) -> Response {
        let response = Response()
        response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        response.headers.replaceOrAdd(name: .connection, value: "keep-alive")
        response.headers.replaceOrAdd(name: "Access-Control-Allow-Origin", value: "*")
        response.headers.replaceOrAdd(name: "Access-Control-Allow-Headers", value: "Cache-Control")

        response.body = Response.Body(asyncStream: { writer in
            let responseId = "chatcmpl-\(UUID().uuidString)"
            let created = Int(Date().timeIntervalSince1970)

            func chunk(_ delta: ChatCompletionDelta, finishReason: String? = nil)
                -> ChatCompletionStreamResponse
            {
                ChatCompletionStreamResponse(
                    id: responseId,
                    object: "chat.completion.chunk",
                    created: created,
                    model: appleModel.rawValue,
                    choices: [
                        ChatCompletionStreamChoice(
                            index: 0, delta: delta, finishReason: finishReason)
                    ]
                )
            }

            do {
                let (session, prompt) = try await aiManager.prepareSession(
                    for: chatRequest.messages, model: appleModel)
                let options = aiManager.makeOptions(
                    temperature: chatRequest.temperature, maxTokens: chatRequest.responseTokenLimit)

                // First chunk carries the role
                try await writer.write(
                    .buffer(Self.sseEvent(chunk(ChatCompletionDelta(role: "assistant", content: "")))))

                if let output {
                    // Partial structured output isn't valid JSON, so send the finished object once
                    let json: String
                    switch output {
                    case .guided(let schema):
                        var finalContent: GeneratedContent?
                        for try await snapshot in session.streamResponse(
                            to: prompt, schema: schema, options: options)
                        {
                            finalContent = snapshot.content
                        }
                        json = finalContent?.jsonString ?? "{}"
                    case .tagList(let shape):
                        var text = ""
                        for try await snapshot in session.streamResponse(to: prompt, options: options) {
                            text = snapshot.content
                        }
                        json = try shape.json(from: text)
                    }
                    try await writer.write(
                        .buffer(Self.sseEvent(chunk(ChatCompletionDelta(content: json)))))
                    try await writer.write(
                        .buffer(Self.sseEvent(chunk(ChatCompletionDelta(), finishReason: "stop"))))
                    try? await writer.write(.buffer(ByteBuffer(string: "data: [DONE]\n\n")))
                    try? await writer.write(.end)
                    return
                }

                // Each snapshot holds the full text generated so far; send only the new part
                var previousContent = ""
                for try await snapshot in session.streamResponse(to: prompt, options: options) {
                    let content = snapshot.content
                    let delta =
                        content.hasPrefix(previousContent)
                        ? String(content.dropFirst(previousContent.count))
                        : content
                    previousContent = content

                    if delta.isEmpty { continue }
                    try await writer.write(
                        .buffer(Self.sseEvent(chunk(ChatCompletionDelta(content: delta)))))
                }

                try await writer.write(
                    .buffer(Self.sseEvent(chunk(ChatCompletionDelta(), finishReason: "stop"))))
            } catch {
                let failure = GenerationFailure(error)
                if let buffer = try? Self.sseEvent(failure.errorResponse) {
                    try? await writer.write(.buffer(buffer))
                }
            }

            try? await writer.write(.buffer(ByteBuffer(string: "data: [DONE]\n\n")))
            try? await writer.write(.end)
        })

        return response
    }

    deinit {
        Task { [app] in
            try? await app?.asyncShutdown()
        }
    }
}
