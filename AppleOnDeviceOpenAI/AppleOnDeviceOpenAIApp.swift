//
//  AppleOnDeviceOpenAIApp.swift
//  AppleOnDeviceOpenAI
//
//  Created by Channing Dai on 6/15/25.
//

import AppKit
import SwiftUI

/// UserDefaults key for showing the app in the Dock (regular app) instead of menu bar only
let showInDockKey = "showInDock"

/// Switch between a regular Dock app and a menu-bar-only (accessory) app
func applyDockVisibility(_ showInDock: Bool) {
    NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement starts the app as accessory; promote it if Dock mode is on
        if UserDefaults.standard.bool(forKey: showInDockKey) {
            applyDockVisibility(true)
            NSApp.activate()
        }
    }
}

@main
struct AppleOnDeviceOpenAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = ServerViewModel()
    @AppStorage(showInDockKey) private var showInDock = false

    var body: some Scene {
        // Lives in the menu bar (LSUIElement = YES hides the Dock icon unless Dock mode is on)
        MenuBarExtra {
            ContentView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.isRunning ? "brain.head.profile.fill" : "brain.head.profile")
        }
        .menuBarExtraStyle(.window)

        Window("Chat", id: chatWindowID) {
            ChatView()
        }
        .defaultSize(width: 640, height: 720)
        // Open the chat window at launch only in Dock mode
        .defaultLaunchBehavior(showInDock ? .presented : .suppressed)
    }
}
