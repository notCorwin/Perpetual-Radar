import Foundation
import UserNotifications

enum MarketNotificationAuthorization: String, Sendable {
    case notDetermined, denied, authorized, quiet, unavailable
    var canDeliver: Bool { self == .authorized || self == .quiet }
}

@MainActor
protocol MarketNotificationTransport {
    func authorization() async -> MarketNotificationAuthorization
    func requestAuthorization() async throws
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
struct SystemMarketNotificationTransport: MarketNotificationTransport {
    let center: UNUserNotificationCenter
    func authorization() async -> MarketNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional: return settings.alertSetting == .enabled ? .authorized : .quiet
        default: return .unavailable
        }
    }
    func requestAuthorization() async throws { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}

@MainActor
final class MarketNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let transport: any MarketNotificationTransport
    private let enabled: () -> Bool
    var onOpen: ((String?) -> Void)?
    var onStateChanged: (() -> Void)?
    private(set) var authorization = MarketNotificationAuthorization.notDetermined
    private(set) var error = ""

    init(transport: any MarketNotificationTransport, enabled: @escaping () -> Bool) {
        self.transport = transport; self.enabled = enabled
    }

    func refresh(requestPermission: Bool = false) async {
        authorization = await transport.authorization()
        if requestPermission, authorization == .notDetermined {
            do { try await transport.requestAuthorization(); error = "" }
            catch { self.error = "Cannot request notification permission: \(error.localizedDescription)" }
            authorization = await transport.authorization()
        }
        onStateChanged?()
    }

    func send(_ changes: [FilterMembershipChange]) async {
        guard enabled(), !changes.isEmpty else { return }
        await refresh()
        guard enabled(), authorization.canDeliver else { return }
        for change in changes {
            guard enabled(), !Task.isCancelled else { return }
            let content = UNMutableNotificationContent()
            content.title = change.direction == .entered ? "Contract entered filters" : "Contract exited filters"
            content.subtitle = change.instId
            content.body = change.direction == .entered
                ? "This OKX USDT perpetual swap now matches your saved 1h filters."
                : "This OKX USDT perpetual swap no longer matches your saved 1h filters or has left the exchange universe."
            content.sound = .default
            content.threadIdentifier = "saved-market-filters"
            content.userInfo = ["instId": change.instId, "direction": change.direction.rawValue]
            await deliver(content)
        }
    }

    func sendTest() async {
        await refresh(requestPermission: true)
        guard authorization.canDeliver else { return }
        let content = UNMutableNotificationContent()
        content.title = "Perpetual Radar"
        content.body = "Filter notifications are working. Monitoring continues when you close the window."
        content.sound = .default
        await deliver(content)
    }

    private func deliver(_ content: UNMutableNotificationContent) async {
        do {
            try await transport.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            error = ""
        } catch { self.error = "Cannot send notification: \(error.localizedDescription)" }
        onStateChanged?()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let instId = response.notification.request.content.userInfo["instId"] as? String
            Task { @MainActor [weak self] in self?.onOpen?(instId) }
        }
        completionHandler()
    }
}
