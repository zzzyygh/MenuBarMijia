import Foundation
import Testing
@testable import MijiaCore

/// #276: the Home Assistant token only crosses the internet unencrypted after the user agrees, per address.
struct HAPlaintextConsentTests {
    static let publicHTTP = "http://203.0.113.5:8123"

    private static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.ha.plaintext.\(UUID().uuidString)")!
    }

    @Test("https and local-network addresses never ask; public plain http does")
    func whoNeedsConsent() {
        for url in ["https://myhome.duckdns.org", "https://203.0.113.5:8123", "http://192.168.1.20:8123",
                    "http://homeassistant.local:8123", "http://homeassistant:8123", "http://100.101.102.103:8123",
                    "192.168.1.20:8123"] {
            #expect(!HAPlaintextConsent.needsConsent(url), "\(url)")
        }
        for url in [Self.publicHTTP, "http://myhome.duckdns.org:8123", "http://ha.example.com/"] {
            #expect(HAPlaintextConsent.needsConsent(url), "\(url)")
        }
    }

    @Test("Consent is remembered per address, a changed address asks again, revoke clears all")
    func perAddressConsent() {
        let defaults = Self.freshDefaults()
        #expect(!HAPlaintextConsent.allowsToken(to: Self.publicHTTP, defaults: defaults))
        HAPlaintextConsent.approve(Self.publicHTTP, defaults: defaults)
        #expect(HAPlaintextConsent.allowsToken(to: Self.publicHTTP, defaults: defaults))
        #expect(HAPlaintextConsent.allowsToken(to: "HTTP://203.0.113.5:8123/", defaults: defaults))
        #expect(HAPlaintextConsent.allowsToken(to: "http://203.0.113.5:8123/api/camera_proxy/camera.door", defaults: defaults))
        #expect(!HAPlaintextConsent.allowsToken(to: "http://203.0.113.5:8124", defaults: defaults))
        #expect(!HAPlaintextConsent.allowsToken(to: "http://203.0.113.6:8123", defaults: defaults))
        HAPlaintextConsent.revokeAll(defaults: defaults)
        #expect(!HAPlaintextConsent.allowsToken(to: Self.publicHTTP, defaults: defaults))
    }

    @Test("Without consent the provider asks and sends nothing, neither WebSocket nor REST")
    func providerWaitsForConsent() async throws {
        let asked = ReportedURLs()
        let provider = HAWebSocketProvider(
            baseURLString: Self.publicHTTP,
            token: "secret-token",
            rediscover: { _ in [] },
            allowsToken: { _ in false },
            onPlaintextConsentNeeded: { url in Task { await asked.add(url) } }
        )
        var statuses: [ConnectionStatus] = []
        for await event in provider.events() {
            if case .statusChanged(let status) = event { statuses.append(status) }
            if case .disconnected = statuses.last { break }
        }
        #expect(statuses == [.disconnected(HAPlaintextConsent.waitingMessage(Self.publicHTTP))])
        for _ in 0..<40 where await asked.items.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await asked.items == [Self.publicHTTP])

        await #expect(throws: HomeProviderError.networkError(HAPlaintextConsent.waitingMessage(Self.publicHTTP))) {
            try await provider.execute(.setSwitch(entityId: "switch.kettle", isOn: true))
        }
        await provider.shutdown()
    }

    @Test("允许 remembers the address; 不连接 keeps a readable reason; revoke forgets every consent")
    @MainActor
    func storeFlow() async throws {
        let store = HomeStore(provider: MockHomeProvider(snapshot: SynthesizedHome()), defaultsSuiteName: "test.ha.plaintext.store.\(UUID().uuidString)")

        store.pendingHAPlaintextConsent = Self.publicHTTP
        store.declineHAPlaintext()
        #expect(store.pendingHAPlaintextConsent == nil)
        #expect(!HAPlaintextConsent.isApproved(Self.publicHTTP, defaults: store.userDefaults))

        store.pendingHAPlaintextConsent = Self.publicHTTP
        store.allowHAPlaintext()
        #expect(store.pendingHAPlaintextConsent == nil)
        #expect(HAPlaintextConsent.isApproved(Self.publicHTTP, defaults: store.userDefaults))

        store.signOutAndRevokeAll()
        #expect(!HAPlaintextConsent.isApproved(Self.publicHTTP, defaults: store.userDefaults))
    }
}

actor ReportedURLs {
    private(set) var items: [String] = []
    func add(_ url: String) { items.append(url) }
}
