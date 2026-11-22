import Foundation
import UserNotifications

public enum NotificationEventType: Sendable {
    case volumeMounted(volume: String, fsKind: String, mountPoint: String)
    case volumeUnmounted(volume: String)
    case volumeDetected(volume: String, fsKind: String)
    case mountFailed(volume: String, error: String)
    case repairCompleted(volume: String, success: Bool, details: String)
    case formatCompleted(volume: String, fsKind: String)

    public var title: String {
        switch self {
        case .volumeMounted:
            return "Volume Mounted"
        case .volumeUnmounted:
            return "Volume Unmounted"
        case .volumeDetected:
            return "Filesystem Detected"
        case .mountFailed:
            return "Mount Failed"
        case .repairCompleted(_, let success, _):
            return success ? "Repair Succeeded" : "Repair Warnings"
        case .formatCompleted:
            return "Format Complete"
        }
    }

    public var body: String {
        switch self {
        case .volumeMounted(let volume, let fsKind, let mountPoint):
            return "\(volume) (\(fsKind)) mounted at \(mountPoint)"
        case .volumeUnmounted(let volume):
            return "\(volume) safely detached"
        case .volumeDetected(let volume, let fsKind):
            return "\(volume) contains \(fsKind) filesystem"
        case .mountFailed(let volume, let error):
            return "\(volume): \(error)"
        case .repairCompleted(let volume, let success, let details):
            let summary = success ? "Filesystem is clean" : "Issues detected"
            return "\(volume): \(summary). \(details.prefix(100))"
        case .formatCompleted(let volume, let fsKind):
            return "\(volume) formatted as \(fsKind)"
        }
    }
}

public final class NotificationManager: @unchecked Sendable {
    public static let shared = NotificationManager()

    private var authorized: Bool = false
    private let center: UNUserNotificationCenter?

    private init() {
        if Bundle.main.bundleIdentifier != nil {
            self.center = UNUserNotificationCenter.current()
        } else {
            self.center = nil
        }
    }

    public func requestAuthorization() {
        guard let center = self.center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
        }
    }

    public func post(event: NotificationEventType) {
        if let center = self.center {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )

            center.add(request) { error in
                if let error = error {
                    Self.dispatchViaAppleScript(title: event.title, body: event.body)
                    _ = error
                }
            }
        } else {
            Self.dispatchViaAppleScript(title: event.title, body: event.body)
        }
    }

    private static func dispatchViaAppleScript(title: String, body: String) {
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" subtitle \"Montserrat\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        try? process.run()
    }
}
