# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a macOS SwiftUI application that creates an OpenAI-compatible API server using Apple's on-device Foundation Models. The server exposes local Apple Intelligence models through familiar OpenAI API endpoints, enabling developers to use Apple's on-device AI with existing OpenAI-compatible tools.

**Important**: This is a GUI application (not a CLI tool) to avoid Apple's rate limiting policies for Foundation Models. Command-line tools are rate-limited, but foreground GUI apps are not. It runs as a menu bar app (`MenuBarExtra` + `INFOPLIST_KEY_LSUIElement = YES`), so by default it has no Dock icon or main window. The "Show in Dock" setting (`showInDock` in UserDefaults) switches the activation policy to `.regular` at runtime.

## Requirements

- macOS 26.0 or newer (macOS 27 supported)
- Xcode 26.0 or newer (for building); building with Xcode 27 (Swift 6.4) enables Private Cloud Compute, image input and handling of macOS 27's `LanguageModelError`
- Apple Intelligence must be enabled in Settings > Apple Intelligence & Siri
- Private Cloud Compute model requires macOS 27. All macOS 27 APIs sit under `#if compiler(>=6.4)` + `#available(macOS 27.0, *)` so the app still builds with Xcode 26 and runs on macOS 26 (deployment target is 26.0)
- Device must support Apple Intelligence (Mac with Apple Silicon)

## Building and Running

### Build and run in Xcode:
```bash
open AppleOnDeviceOpenAI.xcodeproj
# Then build and run using Xcode (Cmd+R)
```

### Build from the command line:
```bash
xcodebuild -project AppleOnDeviceOpenAI.xcodeproj -scheme AppleOnDeviceOpenAI \
  -configuration Debug -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" build
open build/Build/Products/Debug/AppleOnDeviceOpenAI.app
```

The app is sandboxed, so `kill`/`pkill` may not stop it; quit it with:
```bash
osascript -e 'tell application id "com.littlecarved.AppleOnDeviceOpenAI" to quit'
```

### Testing the server:
```bash
python3 -m venv .venv && .venv/bin/pip install openai requests
.venv/bin/python test_server.py
```

The test script verifies server health, model availability, OpenAI SDK compatibility, multi-turn conversations, multilingual support, and streaming functionality.

## Architecture

### Core Components

**AppleOnDeviceOpenAIApp** (`AppleOnDeviceOpenAIApp.swift`)
- Owns the single `ServerViewModel` and shows `ContentView` in a `MenuBarExtra` (`.window` style)
- Menu bar icon switches to the filled symbol while the server is running
- `applyDockVisibility(_:)` toggles `.regular` / `.accessory`; `AppDelegate` applies the saved setting at launch
- `Window` scene (`chatWindowID`) hosts `ChatView`; it opens at launch only in Dock mode

**ChatView** (`ChatView.swift`)
- `ChatViewModel` keeps one `LanguageModelSession` per conversation (created via `AppleModel.makeSession`) and streams replies
- Talks to the model directly, not through the HTTP server
- Switching models or "New Chat" resets the session
- Image attachments (file picker, URL, drag and drop) are loaded with `ImageLoader` and sent as `Attachment(cgImage)` in a `PromptBuilder` prompt; gated by `AppleModel.supportsImages` (macOS 27 + `.vision` capability)
- Don't `import Vapor` in SwiftUI files: Vapor's `View` makes SwiftUI's `View` ambiguous

**AppleModel** (`Services/OnDeviceModelManager.swift`)
- Enum of models selectable through the OpenAI `model` field: `apple-on-device`, `apple-on-device-content-tagging`, `apple-private-cloud-compute`
- `init(requested:)` falls back to `apple-on-device` for unknown ids
- `availability()`, `supportsImages` and `makeSession(transcript:)` per model; PCC is only available on macOS 27+

**VaporServerManager** (`Services/VaporServerManager.swift`)
- Main HTTP server using the Vapor framework
- Manages server lifecycle (start/stop)
- Configures OpenAI-compatible API routes
- Handles both streaming and non-streaming responses
- **Important**: Bootstraps logging system only once per process to avoid errors when restarting server

**OnDeviceModelManager** (`Services/OnDeviceModelManager.swift`)
- Actor-isolated manager for Apple's SystemLanguageModel
- Checks model availability and returns detailed error reasons
- Converts OpenAI chat messages to Apple's Transcript format
- Handles conversation context by converting message history to transcript entries
- `prepareSession(for:model:)` builds the session (history) and prompt (last message, with images) shared by the streaming and non-streaming paths
- Supports temperature and max_completion_tokens / max_tokens parameters
- `GenerationFailure` maps generation errors to OpenAI-style error JSON and HTTP status

**ImageLoader** (`Services/ImageLoader.swift`)
- Loads `image_url` values (base64 data URLs and http(s); 20 MB limit, 30 s timeout; `file://` rejected) and decodes them with ImageIO
- Shared by the API and the chat window

**ContentView** (`ContentView.swift`)
- Menu bar panel UI with server configuration and status; receives the shared `ServerViewModel`
- Lists every model with its availability, plus "Show in Dock" toggle, "Open Chat" and Quit buttons
- Displays server URLs, endpoints, and integration examples
- Provides network interface picker for bind address (127.0.0.1, 0.0.0.0, or specific IPs)
- Includes refresh button to rescan network interfaces
- Shows LAN visibility warning when binding to non-localhost addresses

**OpenAIModels** (`Models/OpenAIModels.swift`)
- Defines OpenAI-compatible request/response structures
- Uses snake_case for JSON keys (e.g., `max_tokens`, `finish_reason`)
- All models are `nonisolated` and `Sendable` for actor isolation safety
- Includes streaming-specific models (`ChatCompletionStreamResponse`, `ChatCompletionDelta`)

### Message Flow

1. Client sends OpenAI-compatible request to `/v1/chat/completions`
2. VaporServerManager validates request, extracts messages array, and resolves `AppleModel` from the `model` field
3. OnDeviceModelManager converts message history (excluding last message) to Transcript entries
4. System/developer messages → merged into a single leading Transcript.Instructions entry
5. User (and tool/unknown) messages → Transcript.Prompt (with image attachment segments on macOS 27)
6. Assistant messages → Transcript.Response
7. Last message becomes the current prompt (a `Prompt` built with `Attachment`s when it has images)
8. LanguageModelSession is created for the selected model with conversation transcript
9. Response is generated and returned in OpenAI format

### Streaming Implementation

Streaming uses Server-Sent Events (SSE):
- Sets proper headers (`text/event-stream`, `Cache-Control: no-cache`, etc.)
- Uses Vapor's `Response.Body(asyncStream:)` for async streaming
- Errors are sent as a JSON-encoded `{"error": …}` SSE event before `[DONE]`
- Tracks cumulative content and sends only deltas
- First chunk includes role ("assistant")
- Final chunk has `finish_reason: "stop"`
- Ends with `data: [DONE]` message

## API Endpoints

- `GET /health` - Health check (returns 200 OK)
- `GET /status` - Model availability, supported languages, bundle version, `image_input_supported`, per-model `models` array
- `GET /v1/models` - List currently available models (OpenAI-compatible)
- `POST /v1/chat/completions` - Chat completions (streaming and non-streaming)

Default server address: `http://127.0.0.1:11535`

## Common Patterns

### Model Availability Checking
Always check model availability before generating responses. The system provides detailed error reasons:
- `deviceNotEligible` - Hardware doesn't support Apple Intelligence
- `appleIntelligenceNotEnabled` - Settings not configured
- `modelNotReady` - Model still downloading

### Conversation Context
Multi-turn conversations work by passing all previous messages in the request. The manager builds a transcript from message history, maintaining context across turns.

### Actor Isolation
OnDeviceModelManager is an actor to safely manage the SystemLanguageModel. All calls to it use `await` and run on the actor's isolated context.

### Server Configuration Persistence
Server configuration (host/port) is stored in ServerConfiguration struct. The UI uses separate input bindings (`hostInput`, `portInput`) that update the configuration when starting the server.

## Known Issues

- Rate limiting may still occur due to Apple FoundationModels limitations - restart the server if this happens
- Logging system can only be initialized once per process (handled by `loggingBootstrapped` flag)
