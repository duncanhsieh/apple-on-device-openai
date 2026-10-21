#!/usr/bin/env python3
"""
Test Apple On-Device OpenAI Compatible Server
Make sure the server is running at http://localhost:11535 before running this script
"""

import base64
import requests
import json
import struct
import zlib
from openai import OpenAI

# Server addresses
BASE_URL = "http://127.0.0.1:11535"
API_BASE_URL = f"{BASE_URL}/v1"

def test_health_check():
    """Test health check endpoint"""
    print("🔍 Testing health check...")
    try:
        response = requests.get(f"{BASE_URL}/health")
        if response.status_code == 200:
            print("✅ Health check passed")
            return True
        else:
            print(f"❌ Health check failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Connection failed: {e}")
        return False

def test_status():
    """Test status endpoint"""
    print("\n🔍 Testing server status...")
    try:
        response = requests.get(f"{BASE_URL}/status")
        if response.status_code == 200:
            data = response.json()
            print("✅ Status check passed")
            print(f"   Model available: {data.get('model_available', False)}")
            print(f"   Reason: {data.get('reason', 'N/A')}")
            print(f"   Supported languages count: {len(data.get('supported_languages', []))}")
            print(f"   Image input supported: {data.get('image_input_supported', False)}")
            return data.get('model_available', False)
        else:
            print(f"❌ Status check failed: {response.status_code}")
            return False
    except Exception as e:
        print(f"❌ Status check error: {e}")
        return False

def test_models_list():
    """Test models list endpoint using OpenAI SDK"""
    print("\n🔍 Testing models list (OpenAI SDK)...")
    try:
        client = OpenAI(
            base_url=API_BASE_URL,
            api_key="dummy-key"  # No real API key needed
        )
        
        models = client.models.list()
        print("✅ Models list retrieved successfully")
        print(f"   Available models count: {len(models.data)}")
        for model in models.data:
            print(f"   - {model.id}")
        return True
    except Exception as e:
        print(f"❌ Models list retrieval error: {e}")
        print(e) 
        return False

def test_chat_completion_openai_sdk():
    """Test multi-turn chat completion using OpenAI SDK"""
    print("\n🔍 Testing multi-turn chat completion (OpenAI SDK)...")
    try:
        client = OpenAI(
            base_url=API_BASE_URL,
            api_key="dummy-key"  # No real API key needed
        )
        
        response = client.chat.completions.create(
            model="apple-on-device",
            messages=[
                {"role": "user", "content": "What are the benefits of on-device AI?"},
                {"role": "assistant", "content": "On-device AI offers several key benefits including improved privacy, faster response times, reduced reliance on internet connectivity, and better data security since processing happens locally on your device."},
                {"role": "user", "content": "Can you elaborate on the privacy benefits?"},
            ],
            max_tokens=200
        )
        
        print("✅ Multi-turn OpenAI SDK call successful")
        print(f"   Response ID: {response.id}")
        print(f"   Model: {response.model}")
        print(f"   AI Response: {response.choices[0].message.content}")
        return True
    except Exception as e:
        print(f"❌ Multi-turn OpenAI SDK call failed: {e}")
        print(e) 
        return False

def test_chinese_conversation():
    """Test Chinese conversation using OpenAI SDK"""
    print("\n🔍 Testing Chinese conversation (OpenAI SDK)...")
    try:
        client = OpenAI(
            base_url=API_BASE_URL,
            api_key="dummy-key"  # No real API key needed
        )
        
        response = client.chat.completions.create(
            model="apple-on-device",
            messages=[
                {"role": "user", "content": "你好！请用中文解释一下什么是苹果智能。"}
            ],
            max_tokens=200
        )
        
        print("✅ Chinese conversation successful")
        print(f"   AI Response: {response.choices[0].message.content}")
        return True
    except Exception as e:
        print(f"❌ Chinese conversation error: {e}")
        return False

def test_streaming_chat_completion():
    """Test streaming chat completion using OpenAI SDK"""
    print("\n🔍 Testing streaming chat completion (OpenAI SDK)...")
    try:
        client = OpenAI(
            base_url=API_BASE_URL,
            api_key="dummy-key"  # No real API key needed
        )
        
        stream = client.chat.completions.create(
            model="apple-on-device",
            messages=[
                {"role": "user", "content": "Tell me a short story about AI helping humans."}
            ],
            max_tokens=150,
            stream=True
        )
        
        print("✅ Streaming chat completion started")
        collected_content = ""
        chunk_count = 0
        
        for chunk in stream:
            if chunk.choices[0].delta.content is not None:
                content = chunk.choices[0].delta.content
                collected_content += content
                chunk_count += 1
                print(f"   Chunk {chunk_count}: '{content}'")
        
        print(f"✅ Streaming completed with {chunk_count} chunks")
        print(f"   Full response: {collected_content}")
        return True
    except Exception as e:
        print(f"❌ Streaming chat completion failed: {e}")
        return False


def solid_color_png_data_url(rgb=(255, 0, 0), size=64):
    """Build a data URL for a solid color PNG without third-party dependencies"""
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    row = b"\x00" + bytes(rgb) * size
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(row * size))
        + chunk(b"IEND", b"")
    )
    return "data:image/png;base64," + base64.b64encode(png).decode()

def test_image_input():
    """Test image input (macOS 27+); expects a 400 when the server doesn't support it"""
    print("\n🖼️  Testing image input...")
    supported = requests.get(f"{BASE_URL}/status").json().get("image_input_supported", False)
    payload = {
        "model": "apple-on-device",
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": "What color is this image? Answer with one word."},
                {"type": "image_url", "image_url": {"url": solid_color_png_data_url()}},
            ],
        }],
    }
    try:
        response = requests.post(f"{API_BASE_URL}/chat/completions", json=payload)
        if supported and response.status_code == 200:
            print("✅ Image input passed")
            print(f"   Response: {response.json()['choices'][0]['message']['content']}")
            return True
        if not supported and response.status_code == 400:
            print("✅ Image input correctly rejected (not supported on this system)")
            print(f"   Reason: {response.json()['error']['message']}")
            return True
        print(f"❌ Image input failed: {response.status_code} {response.text}")
        return False
    except Exception as e:
        print(f"❌ Image input error: {e}")
        return False

def test_structured_output():
    """Test response_format json_schema on the general and content tagging models"""
    print("\n🧩 Testing structured output (response_format json_schema)...")
    client = OpenAI(base_url=API_BASE_URL, api_key="dummy-key")
    text = "Apple unveiled new MacBook Pro models with M5 chips. Tim Cook said they ship next week."
    topics = {"type": "object", "required": ["topics"], "properties": {
        "topics": {"type": "array", "items": {"type": "string"}, "maxItems": 3}}}
    review = {"type": "object", "required": ["sentiment", "rating"], "properties": {
        "sentiment": {"type": "string", "enum": ["positive", "negative", "neutral"]},
        "rating": {"type": "integer", "minimum": 1, "maximum": 5}}}
    ok = True
    for model, schema, check in [
        ("apple-on-device-content-tagging", topics, lambda r: len(r["topics"]) <= 3),
        ("apple-on-device", review, lambda r: r["sentiment"] in review["properties"]["sentiment"]["enum"]
            and 1 <= r["rating"] <= 5),
    ]:
        try:
            response = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": text}],
                response_format={"type": "json_schema", "json_schema": {"name": "Result", "schema": schema}},
            )
            result = json.loads(response.choices[0].message.content)
            if check(result):
                print(f"✅ {model}: {json.dumps(result, ensure_ascii=False)}")
            else:
                print(f"❌ {model}: output doesn't match the schema: {result}")
                ok = False
        except Exception as e:
            print(f"❌ {model}: {e}")
            ok = False
    return ok

def main():
    """Main test function"""
    print("🚀 Starting Apple On-Device OpenAI Compatible Server Tests")
    print("=" * 60)
    
    # Basic connection test
    if not test_health_check():
        print("\n❌ Server unreachable, please ensure the server is running")
        return
    
    # Status check
    model_available = test_status()
    
    # Models list (using OpenAI SDK)
    test_models_list()
    
    # If model is available, run chat tests (using OpenAI SDK)
    if model_available:
        print("\n" + "=" * 60)
        print("🤖 Model available, starting chat tests")
        print("=" * 60)
        
        test_chat_completion_openai_sdk()
        test_chinese_conversation()
        test_image_input()
        test_structured_output()
        
        print("\n" + "=" * 60)
        print("🌊 Testing streaming functionality")
        print("=" * 60)
        
        test_streaming_chat_completion()
        
        print("\n" + "=" * 60)
        print("✅ All tests completed!")
        print("\n💡 You can now use any OpenAI-compatible client to connect to:")
        print(f"   Base URL: {API_BASE_URL}")
        print("   API Key: any value (no real API key needed)")
        print("   Model: apple-on-device")
    else:
        print("\n⚠️  Model unavailable, skipping chat tests")
        print("Please ensure:")
        print("1. Device supports Apple Intelligence")
        print("2. Apple Intelligence is enabled in Settings")
        print("3. Model download is complete")

if __name__ == "__main__":
    main() 