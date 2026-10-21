//
//  SettingsView.swift
//  AppleOnDeviceOpenAI
//

import SwiftUI

// MARK: - Settings Window
struct SettingsView: View {
    @ObservedObject var viewModel: ServerViewModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Server", systemImage: "network") {
                ServerSettingsView(viewModel: viewModel)
            }
            Tab("API", systemImage: "chevron.left.forwardslash.chevron.right") {
                APISettingsView(viewModel: viewModel)
            }
        }
        .frame(width: 520)
    }
}

// MARK: - General
struct GeneralSettingsView: View {
    @AppStorage(showInDockKey) private var showInDock = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $showInDock) {
                    Text("Show in Dock")
                    Text("Run as a regular app with a Dock icon. The chat window opens at launch.")
                }
                .onChange(of: showInDock) { _, newValue in
                    applyDockVisibility(newValue)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 110)
    }
}

// MARK: - Server
struct ServerSettingsView: View {
    @ObservedObject var viewModel: ServerViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Bind Address") {
                    HStack(spacing: 6) {
                        Picker("Bind Address", selection: $viewModel.selectedAddress) {
                            ForEach(viewModel.availableAddresses, id: \.self) { address in
                                Text(Self.label(for: address)).tag(address)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()

                        Button {
                            viewModel.refreshAddresses()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .iconFrame()
                        }
                        .buttonStyle(.borderless)
                        .help("Rescan network interfaces")
                    }
                }

                LabeledContent("Port") {
                    TextField("Port", text: $viewModel.portInput, prompt: Text("11535"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        if viewModel.needsLANWarning {
                            Label(
                                "Other devices on your network can reach the server. Only use this on networks you trust.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                        if viewModel.isRunning {
                            Text("Stop the server to change these settings.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)

                    Spacer()

                    Button("Restore Defaults") {
                        viewModel.resetToDefaults()
                    }
                }
            }
            .disabled(viewModel.isRunning)
        }
        .formStyle(.grouped)
        .frame(height: 200)
    }

    private static func label(for address: String) -> String {
        switch address {
        case "127.0.0.1": return "This Mac only (127.0.0.1)"
        case "0.0.0.0": return "All interfaces (0.0.0.0)"
        default: return address
        }
    }
}

// MARK: - API
struct APISettingsView: View {
    @ObservedObject var viewModel: ServerViewModel

    private var pythonExample: String {
        """
        from openai import OpenAI

        client = OpenAI(base_url="\(viewModel.openaiBaseURL)", api_key="not-needed")

        response = client.chat.completions.create(
            model="\(AppleModel.onDevice.rawValue)",
            messages=[{"role": "user", "content": "Hello!"}],
        )
        print(response.choices[0].message.content)
        """
    }

    var body: some View {
        Form {
            Section("Endpoints") {
                LabeledContent("Base URL") {
                    HStack {
                        Text(viewModel.openaiBaseURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(text: viewModel.openaiBaseURL)
                    }
                }
                EndpointRow(method: "GET", path: "/health", summary: "Health check")
                EndpointRow(method: "GET", path: "/status", summary: "Model availability")
                EndpointRow(method: "GET", path: "/v1/models", summary: "List models")
                EndpointRow(method: "POST", path: "/v1/chat/completions", summary: "Chat completions")
            }

            Section {
                Text(pythonExample)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                HStack {
                    Text("Python")
                    Spacer()
                    CopyButton(text: pythonExample)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }
}

struct EndpointRow: View {
    let method: String
    let path: String
    let summary: String

    var body: some View {
        LabeledContent {
            Text(summary)
                .foregroundStyle(.secondary)
        } label: {
            HStack(spacing: 8) {
                Text(method)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(method == "POST" ? Color.blue : Color.green)
                    .frame(width: 36, alignment: .leading)
                Text(path)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: ServerViewModel())
}
