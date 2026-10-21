# Apple On-Device OpenAI API

A SwiftUI application that creates an OpenAI-compatible API server using Apple's on-device Foundation Models. This allows you to use Apple Intelligence models locally through familiar OpenAI API endpoints.

## Screenshot

<img src="assets/server.png" alt="App Screenshot" width="600">

Use it in any OpenAI compatible app:

<img src="assets/chat-app.png" alt="Integration Screenshot" width="600">


## Features

- **OpenAI Compatible API**: Drop-in replacement for OpenAI API with chat completions endpoint
- **Streaming Support**: Real-time streaming responses compatible with OpenAI's streaming format
- **On-Device Processing**: Uses Apple's Foundation Models for completely local AI processing
- **Model Availability Check**: Automatically checks Apple Intelligence availability on startup
- **Menu Bar App**: Lives in the menu bar (no Dock icon by default); the icon fills in while the server is running
- **Optional Dock Mode**: Turn on "Show in Dock" to run it as a regular app with a Dock icon
- **Chat Window**: Built-in chat for trying the models directly, with streaming and multi-turn context; on macOS 27 you can also attach images
- **Model Selection**: Choose the on-device model, its content-tagging mode, or Private Cloud Compute (macOS 27+) via the `model` field
- **🚧 Tool Using (WIP)**: Function calling capabilities for extended AI functionality

## Requirements

- **macOS**: 26 beta 2
- **Apple Intelligence**: Must be enabled in Settings > Apple Intelligence & Siri
- **Xcode**: 26 beta 2 (for building)
- **Private Cloud Compute** (optional): macOS 27 or later; on older systems the model is reported as unavailable

## Installation

### Option 1: Download Pre-built App (Recommended)

1. Go to the [Releases](https://github.com/gety-ai/apple-on-device-openai/releases) page
2. Download the latest `.zip` file
3. Extract and launch the app

### Option 2: Build from Source

1. Clone the repository:
```bash
git clone https://github.com/gety-ai/apple-on-device-openai.git
cd apple-on-device-openai
```

2. Open the project in Xcode:
```bash
open AppleOnDeviceOpenAI.xcodeproj
```

3. Build and run the project in Xcode

Or build from the command line (ad-hoc signed, output in `build/`):
```bash
xcodebuild -project AppleOnDeviceOpenAI.xcodeproj -scheme AppleOnDeviceOpenAI \
  -configuration Debug -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" build
open build/Build/Products/Debug/AppleOnDeviceOpenAI.app
```

## Why a GUI App Instead of Command Line?

This project is implemented as a GUI application rather than a command-line tool due to **Apple's rate limiting policies** for Foundation Models:

> "An app that has UI and runs in the foreground doesn't have a rate limit when using the models; a macOS command line tool, which doesn't have UI, does."
> 
> — Apple DTS Engineer ([Source](https://developer.apple.com/forums/thread/787737))

**⚠️ Important Note**: You may still encounter rate limits due to current limitations in Apple FoundationModels. If you experience rate limiting, please restart the server.

**⚠️ 重要提醒**: 由于苹果 FoundationModels 当前的限制，您仍然可能遇到速率限制。如果遇到这种情况，请重启服务器。

**Menu bar note**: The app runs as a menu bar app, so it is only the foreground app while its panel is open. In practice a regular window loses foreground status too as soon as you switch to another app. When the system rate-limits a request, the server returns HTTP `429` so OpenAI-compatible clients back off and retry.


## Usage

### Starting the Server

1. Launch the app — a brain icon appears in the menu bar (there is no Dock icon or main window)
2. Click the icon to open the panel and configure server settings (default: `127.0.0.1:11535`)
3. Click "Start Server" — the menu bar icon fills in while the server is running
4. Server will be available at the configured address
5. Use the "Quit" button (⌘Q) at the bottom of the panel to exit the app

### Dock Mode and Chat Window

- **Show in Dock**: The toggle at the bottom of the panel switches the app between menu-bar-only and a regular Dock app. It takes effect immediately and is remembered; in Dock mode the chat window opens at launch.
- **Open Chat**: Opens a chat window for talking to the selected model. Pick the model from the toolbar (switching models starts a new chat), press Return to send, and use the stop button to cancel a response. Messages go straight to the model, so the API server doesn't need to be running.
- **Images (macOS 27+)**: Use the paperclip to choose image files or paste an image URL, or drop image files / links onto the chat. Attachments are limited to 20 MB each. The paperclip is disabled on macOS 26 and for models without the vision capability.

Keeping the chat window in front also keeps the app in the foreground, which avoids the background rate limits described above.

### Available Endpoints

Once the server is running, you can access these OpenAI-compatible endpoints:

- `GET /health` - Health check
- `GET /status` - Model availability and status, including a `models` array with each model's availability and reason
- `GET /v1/models` - List models that are currently available on this Mac
- `POST /v1/chat/completions` - Chat completions (streaming and non-streaming)

### Models

Pick a model with the OpenAI `model` field:

| Model ID | Description | Requirements |
|---|---|---|
| `apple-on-device` | On-device model, general use (default) | macOS 26 + Apple Intelligence |
| `apple-on-device-content-tagging` | Same on-device model tuned for tagging / classification; returns short tags | macOS 26 + Apple Intelligence |
| `apple-private-cloud-compute` | Apple's larger server model via Private Cloud Compute | macOS 27 |

- Unknown model IDs (e.g. `gpt-4o` sent by default from existing clients) fall back to `apple-on-device`; the response's `model` field shows the model actually used.
- Requesting an unavailable model returns HTTP `503` with the reason (streaming requests receive the error as an SSE event).
- The on-device model variant (e.g. `core3` / `coreAdvanced3`) is chosen by the system per device and cannot be selected.

### Example Usage

#### Using curl:
```bash
curl -X POST http://127.0.0.1:11535/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "apple-on-device",
    "messages": [
      {"role": "user", "content": "Hello, how are you?"}
    ],
    "temperature": 0.7,
    "stream": false
  }'
```

#### Using OpenAI Python client:
```python
from openai import OpenAI

# Point to your local server
client = OpenAI(
    base_url="http://127.0.0.1:11535/v1",
    api_key="not-needed"  # API key not required for local server
)

response = client.chat.completions.create(
    model="apple-on-device",
    messages=[
        {"role": "user", "content": "Hello, how are you?"}
    ],
    temperature=0.7,
    stream=True  # Enable streaming
)

for chunk in response:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="")
```

## Testing

You can use the included test script to verify the server is working correctly and see example usage patterns:

```bash
python3 -m venv .venv
.venv/bin/pip install openai requests
.venv/bin/python test_server.py
```

The test script will:
- ✅ Check server health and connectivity
- ✅ Verify model availability and status
- ✅ Test OpenAI SDK compatibility
- ✅ Run multi-turn conversations
- ✅ Test multilingual support (Chinese)
- ✅ Demonstrate streaming functionality

Make sure the server is running before executing the test script. The script provides comprehensive examples of how to interact with the API using both direct HTTP requests and the OpenAI Python SDK.

## API Compatibility

This server implements the OpenAI Chat Completions API with the following supported parameters:

- `model` - Model identifier (see [Models](#models); defaults to `apple-on-device`)
- `messages` - Array of conversation messages
- `temperature` - Sampling temperature (0.0 to 2.0)
- `max_tokens` - Maximum tokens in response
- `stream` - Enable streaming responses

## Development Notes

🤖 This project was mainly "vibe coded" using Cursor + Claude Sonnet 4 & ChatGPT o3.


## License

This project is licensed under the MIT License - see the LICENSE file for details.

## References

- [Apple Foundation Models Documentation](https://developer.apple.com/documentation/foundationmodels)
- [OpenAI API Documentation](https://platform.openai.com/docs/api-reference) 