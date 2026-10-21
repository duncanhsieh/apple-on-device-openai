//
//  AppleOnDeviceOpenAIApp.swift
//  AppleOnDeviceOpenAI
//
//  Created by Channing Dai on 6/15/25.
//

import SwiftUI

@main
struct AppleOnDeviceOpenAIApp: App {
    @StateObject private var viewModel = ServerViewModel()

    var body: some Scene {
        // Lives in the menu bar (LSUIElement = YES hides the Dock icon)
        MenuBarExtra {
            ContentView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.isRunning ? "brain.head.profile.fill" : "brain.head.profile")
        }
        .menuBarExtraStyle(.window)
    }
}
