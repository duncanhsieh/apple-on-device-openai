//
//  ContentView.swift
//  AppleOnDeviceOpenAI
//
//  Created by Channing Dai on 6/15/25.
//

import Combine
import SwiftUI
import Foundation
import Network

// MARK: - Models
struct ServerConfiguration {
    var host: String
    var port: Int

    static let `default` = ServerConfiguration(
        host: "127.0.0.1",
        port: 11535
    )

    var url: String {
        "http://\(host):\(port)"
    }

    var openaiBaseURL: String {
        "\(url)/v1"
    }

    var chatCompletionsEndpoint: String {
        "\(url)/v1/chat/completions"
    }
}

// MARK: - ViewModel
@MainActor
class ServerViewModel: ObservableObject {
    @Published var configuration = ServerConfiguration.default
    @Published var hostInput: String = "127.0.0.1"
    @Published var portInput: String = "11535"
    @Published var isModelAvailable: Bool = false
    @Published var modelUnavailableReason: String?
    @Published var isCheckingModel: Bool = false
    @Published var modelStatuses: [ModelStatus] = []

    @Published var availableAddresses: [String] = []
    @Published var selectedAddress: String = "127.0.0.1" {
        didSet { hostInput = selectedAddress }
    }

    private let serverManager = VaporServerManager()
    private var cancellables = Set<AnyCancellable>()

    var isRunning: Bool {
        serverManager.isRunning
    }

    var lastError: String? {
        serverManager.lastError
    }

    /// True whenever the user is binding to something other than 127.0.0.1.
    var needsLANWarning: Bool {
        // Treat “all interfaces” (0.0.0.0) as LAN‑visible too.
        selectedAddress != "127.0.0.1"
    }

    private var advertisedHost: String {
        switch configuration.host {
        case "0.0.0.0":
            // We are listening on *all* interfaces – pick something shareable
            return primaryLANAddress() ?? "127.0.0.1"
        default:
            // The user chose a concrete IP (loop‑back included)
            return configuration.host
        }
    }

    var serverURL: String {
        "http://\(advertisedHost):\(configuration.port)"
    }

    var openaiBaseURL: String {
        "\(serverURL)/v1"
    }

    var chatCompletionsEndpoint: String {
        "\(serverURL)/v1/chat/completions"
    }

    init() {
        refreshAddresses()                              // populate the picker
        selectedAddress = configuration.host

        // Initialize with current configuration values
        self.hostInput = configuration.host
        self.portInput = String(configuration.port)

        // Re-publish server state so the menu bar icon tracks it
        serverManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Check model availability on startup
        Task {
            await checkModelAvailability()
        }
    }

    func checkModelAvailability() async {
        isCheckingModel = true

        let result = await aiManager.isModelAvailable()

        isModelAvailable = result.available
        modelUnavailableReason = result.reason
        modelStatuses = AppleModel.allCases.map { model in
            let (available, reason) = model.availability()
            return ModelStatus(
                id: model.rawValue, available: available, reason: reason,
                imageInput: model.supportsImages)
        }
        isCheckingModel = false
    }

    func startServer() async {
        // Check model availability before starting
        await checkModelAvailability()

        guard isModelAvailable else {
            return
        }

        updateConfiguration()
        await serverManager.startServer(configuration: configuration)
    }

    func stopServer() async {
        await serverManager.stopServer()
    }

    private func updateConfiguration() {
        configuration.host = selectedAddress

        if let port = Int(portInput.trimmingCharacters(in: .whitespacesAndNewlines)),
            port > 0 && port <= 65535
        {
            configuration.port = port
        }
    }

    func resetToDefaults() {
        configuration = ServerConfiguration.default
        selectedAddress = configuration.host
        hostInput = configuration.host
        portInput = String(configuration.port)
    }

    /// Refresh the list (e.g. when a new Wi‑Fi network is joined).
    func refreshAddresses() {
        // Put localhost first, keep “all interfaces”, then the rest.
        availableAddresses = ["127.0.0.1", "0.0.0.0"]
            + currentIPv4Addresses().filter { $0 != "127.0.0.1" }
        // Keep selection valid
        if !availableAddresses.contains(selectedAddress) {
            selectedAddress = availableAddresses.first ?? "0.0.0.0"
        }
    }

    /// Returns all IPv4 addresses currently assigned to the device,
    /// sorted and deduplicated (loop‑back first).
    func currentIPv4Addresses() -> [String] {
        var addresses: Set<String> = []

        var addrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrPointer) == 0 else { return [] }
        defer { freeifaddrs(addrPointer) }

        var ptr = addrPointer
        while let iface = ptr?.pointee {
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                var addr = iface.ifa_addr.pointee
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    &addr,
                    socklen_t(iface.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                addresses.insert(String(cString: hostname))
            }
            ptr = iface.ifa_next
        }

        // Keep loop‑back first, then alphabetical
        return ["127.0.0.1"] + addresses.subtracting(["127.0.0.1"]).sorted()
    }

    /// Return the first non‑loop‑back IPv4 address that is *not* link‑local (169.254.x.x).
    /// Falls back to nil when no such address exists.
    private func primaryLANAddress() -> String? {
        for addr in currentIPv4Addresses() {
            if addr != "127.0.0.1" && !addr.hasPrefix("169.254") {
                return addr          // Wi‑Fi / Ethernet / USB‑C / Thunderbolt, etc.
            }
        }
        return nil
    }
}

// MARK: - Menu Bar Panel
/// Compact, Control Center–style panel: server switch, base URL, models and app commands
struct ContentView: View {
    @ObservedObject var viewModel: ServerViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(12)

            if let issue {
                Divider()
                IssueRow(issue: issue) {
                    Task { await viewModel.checkModelAvailability() }
                }
                .padding(12)
            }

            if viewModel.isRunning {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Base URL")
                    HStack {
                        Text(viewModel.openaiBaseURL)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        CopyButton(text: viewModel.openaiBaseURL)
                    }
                }
                .padding(12)
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Models")
                ForEach(viewModel.modelStatuses, id: \.id) { status in
                    ModelRow(status: status)
                }
            }
            .padding(12)

            Divider()
            VStack(spacing: 0) {
                MenuRow("Open Chat", systemImage: "bubble.left.and.text.bubble.right") {
                    dismiss()
                    openWindow(id: chatWindowID)
                    NSApp.activate()
                }
                MenuRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                    dismiss()
                    openSettings()
                    NSApp.activate()
                }
                .keyboardShortcut(",")
                MenuRow("Quit", systemImage: "power", shortcut: "⌘Q") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(5)
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.gradient)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Intelligence API")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Toggle("Server", isOn: serverBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(isBusy || viewModel.isCheckingModel || !viewModel.isModelAvailable)
                .help(viewModel.isRunning ? "Stop the server" : "Start the server")
        }
    }

    private var serverBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isRunning },
            set: { isOn in
                Task {
                    isBusy = true
                    if isOn {
                        await viewModel.startServer()
                    } else {
                        await viewModel.stopServer()
                    }
                    isBusy = false
                }
            }
        )
    }

    private var statusText: String {
        if viewModel.isRunning {
            return "Running on \(viewModel.configuration.host):\(String(viewModel.configuration.port))"
        }
        if viewModel.isCheckingModel { return "Checking Apple Intelligence…" }
        if !viewModel.isModelAvailable { return "Apple Intelligence unavailable" }
        return "Stopped"
    }

    private var statusColor: Color {
        if viewModel.isRunning { return .green }
        if !viewModel.isModelAvailable && !viewModel.isCheckingModel { return .orange }
        return .secondary
    }

    private var issue: Issue? {
        if let error = viewModel.lastError {
            return Issue(message: error, isError: true, canRetry: false)
        }
        if !viewModel.isModelAvailable && !viewModel.isCheckingModel {
            return Issue(
                message: viewModel.modelUnavailableReason ?? "Apple Intelligence is not available",
                isError: false, canRetry: true)
        }
        return nil
    }
}

// MARK: - Helper Views
struct Issue {
    let message: String
    let isError: Bool
    let canRetry: Bool
}

struct IssueRow: View {
    let issue: Issue
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: issue.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.isError ? .red : .orange)
            Text(issue.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if issue.canRetry {
                Button("Retry", action: onRetry)
                    .controlSize(.small)
            }
        }
    }
}

struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

struct ModelRow: View {
    let status: ModelStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(status.available ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            VStack(alignment: .leading, spacing: 2) {
                Text(status.id)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(status.available ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let reason = status.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            if status.available && status.imageInput {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Accepts images")
            }

            if status.available {
                CopyButton(text: status.id)
            }
        }
    }
}

/// Full-width command row that highlights on hover, like a menu item
struct MenuRow: View {
    let title: String
    let systemImage: String
    let shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    init(
        _ title: String, systemImage: String, shortcut: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct CopyButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

#Preview {
    ContentView(viewModel: ServerViewModel())
}
