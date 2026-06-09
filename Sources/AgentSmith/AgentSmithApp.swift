import SwiftUI
import AppKit
import SmithCore
import Models

@main
struct AgentSmithApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenubarView()
                .environmentObject(appState)
                .frame(width: 380, height: 460)
        } label: {
            // Custom menubar label — no Matrix iconography per CLAUDE.md §10 IP note.
            Image(systemName: "tray.full")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Sets the activation policy to `.accessory` so we have no Dock icon — equivalent to
/// `LSUIElement = true` in Info.plist, but works for `swift run` SPM builds that don't
/// ship an Info.plist. Also boots the orchestrator on app launch (not on first menubar click).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLog.app.info("Agent Smith launched")
        Task { @MainActor in
            AppState.shared.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.app.info("Agent Smith terminating")
    }
}
