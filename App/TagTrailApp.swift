import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import TagTrailCore

@main
struct TagTrailApp: App {
    @NSApplicationDelegateAdaptor(TagTrailAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init() {
        let smokeTest = ProcessInfo.processInfo.arguments.contains("--smoke-demo")
        let selfTest = ProcessInfo.processInfo.arguments.contains("--self-test")
        if smokeTest || selfTest { Self.runSmokeTestAndExit(selfTest: selfTest) }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
                .frame(width: 440, height: 610)
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                    Text(model.menuBarTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150)
                }
                    .accessibilityLabel(model.menuBarAccessibilityLabel)
            }

        }
        .menuBarExtraStyle(.window)

        Window("TagTrail — Full Map", id: "full-map") {
            FullMapWindow()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 540)
        }
        .defaultSize(width: 980, height: 680)

        Window("TagTrail Settings", id: "settings") {
            SettingsWindow()
                .environmentObject(model)
                .frame(minWidth: 560, minHeight: 560)
        }
        .defaultSize(width: 640, height: 700)
        .commands {
            CommandGroup(replacing: .appInfo) {}
            CommandGroup(replacing: .newItem) {}
            CommandMenu("TagTrail") {
                Button("Full Map") { openWindow(id: "full-map") }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("Settings…") { openWindow(id: "settings") }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Quit TagTrail") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    private static func runSmokeTestAndExit(selfTest: Bool) -> Never {
        let command = selfTest ? "self-test" : "smoke-demo"
        let directory = FileManager.default.temporaryDirectory
        let result = SmokeResult()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                if selfTest { try await NativeServiceChecks.run() }
                else { try await AppSmokeRunner.run(directory: directory) }
                result.setSuccess()
            } catch {
                result.setFailure()
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + (selfTest ? 50 : 90)) == .timedOut {
            task.cancel()
            fputs("FAIL TagTrail \(command): timed out.\n", stderr)
            fflush(stderr)
            exit(1)
        }
        if result.succeeded {
            print(selfTest ? "PASS TagTrail self-test" : "PASS TagTrail smoke-demo")
            fflush(stdout)
            exit(0)
        }
        fputs("FAIL TagTrail \(command): local fixture verification failed.\n", stderr)
        fflush(stderr)
        exit(1)
    }
}

final class TagTrailAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

private final class SmokeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var success = false

    var succeeded: Bool { lock.lock(); defer { lock.unlock() }; return success }
    func setSuccess() { lock.lock(); success = true; lock.unlock() }
    func setFailure() { lock.lock(); success = false; lock.unlock() }
}
