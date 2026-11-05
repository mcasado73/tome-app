import SwiftUI
import AppKit
import Sparkle

@main
struct TomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var settings = AppSettings()
    @State private var meetingDetector = MeetingDetector()
    private let updaterController = AppUpdaterController()

    var body: some Scene {
        // A single-instance Window rather than a WindowGroup: ContentView owns the
        // transcription engine and wires up the meeting detector, so a second copy
        // (Cmd+N) would mean two engines racing for the same meeting.
        Window("Tome", id: MainWindow.id) {
            ContentView(settings: settings, meetingDetector: meetingDetector)
                .onAppear {
                    settings.applyScreenShareVisibility()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 320, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
        Settings {
            SettingsView(settings: settings, updater: updaterController.updater)
        }
        MenuBarExtra {
            Text("Tome")
                .font(.headline)
            Divider()
            ShowTomeButton()
            Button("Quit Tome") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarLabel()
        }
    }
}

enum MainWindow {
    static let id = "main"
}

/// The menu bar label is the one view SwiftUI renders on every launch, even when
/// the main window isn't restored (e.g. Tome launched as a login item after the
/// window was closed). Auto-start only arms once ContentView appears, so open the
/// main window from here — otherwise meetings go unrecorded until the user
/// happens to open Tome by hand.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @MainActor private static var didEnsureMainWindow = false

    var body: some View {
        Image(systemName: "book.closed")
            .symbolRenderingMode(.monochrome)
            .task {
                // The status item can be rebuilt later (display changes), so only
                // force the window open once per launch.
                guard !Self.didEnsureMainWindow else { return }
                Self.didEnsureMainWindow = true
                openWindow(id: MainWindow.id)
            }
    }
}

private struct ShowTomeButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Tome") {
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
    }
}

/// Observes new window creation and applies screen-share visibility setting.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hidden = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
        let sharingType: NSWindow.SharingType = hidden ? .none : .readOnly

        for window in NSApp.windows {
            window.sharingType = sharingType
        }

        // Watch for new windows being created (e.g. Settings window)
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let hide = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
                    ? true
                    : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
                let type: NSWindow.SharingType = hide ? .none : .readOnly
                for window in NSApp.windows {
                    window.sharingType = type
                }
            }
        }
    }
}
