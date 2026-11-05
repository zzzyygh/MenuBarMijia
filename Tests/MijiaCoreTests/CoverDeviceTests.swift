import Foundation
import Testing
@testable import MijiaCore

/// #278: a cover in the open position is not an ActiveDevice, so it must stay out of the panel and
/// menu-bar counts while 全关 keeps ignoring it.
struct CoverDeviceTests {
    static let light = SmartDevice(
        id: "light_study", name: "书房灯", roomId: "study", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: true))
    )

    static let openCover = SmartDevice(
        id: "wd1", name: "卧室窗户", roomId: "bed", roomName: "卧室",
        model: "linp.wopener.wd1lb", isOnline: true,
        kind: .cover(CoverSpec(
            entityId: "miot:wd1:2",
            subtype: .windowOpener,
            positionPercent: 42,
            positionWritable: true,
            openDescription: "Open",
            closeDescription: "Close",
            pauseDescription: "Pause"
        ))
    )

    @MainActor
    private func makeStore(_ devices: [SmartDevice]) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.cover.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.devices.count == devices.count)
        return (store, mock)
    }

    @Test("An open cover is not counted as an active device on the panel or menu bar")
    @MainActor
    func openCoverIsNotActive() async throws {
        let (store, _) = try await makeStore([Self.light, Self.openCover])
        #expect(store.devices.first { $0.id == Self.openCover.id }?.isActiveOn == true)

        #expect(store.activeDeviceCount == 1)
        store.menuBarTargetId = "active:count"
        #expect(store.menuBarText == "1开")
        store.menuBarDisplayMode = .activeCount
        #expect(store.menuBarText == "1开")
    }

    @Test("Assistant and GrokBall active summaries follow the ActiveDevice rule")
    @MainActor
    func activeSummariesIgnoreOpenCover() async throws {
        let (store, _) = try await makeStore([Self.openCover])
        #expect(store.buildAssistantContext(mention: .none).activeDevicesSummary == "全屋设备均关闭")

        let lateNight = try #require(Calendar.current.date(
            bySettingHour: 23, minute: 30, second: 0, of: Date()
        ))
        #expect(store.grokBallEmotionId(
            speechListening: false, isPointerTracking: false, now: lateNight
        ) == GrokBallEmotionResolver.sleeping)
    }

    @Test("全关 leaves an open cover alone")
    @MainActor
    func allOffIgnoresOpenCover() async throws {
        let (store, _) = try await makeStore([Self.light, Self.openCover])
        #expect(!store.allOffTargets.contains { $0.id == Self.openCover.id })

        store.turnAllOff()
        #expect(store.devices.first { $0.id == Self.light.id }?.isActiveOn == false)
        #expect(store.devices.first { $0.id == Self.openCover.id }?.isActiveOn == true)
    }
}
