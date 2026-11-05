import Foundation
import Testing
@testable import MijiaCore

/// GLOSSARY `BareCategoryCommand` through the store: chips, the all-off choice, undo, and the room
/// the panel shows.
@MainActor
struct BareCategoryCommandStoreTests {
    static func light(_ id: String, _ name: String, roomId: String, roomName: String, isOn: Bool) -> SmartDevice {
        SmartDevice(
            id: id, name: name, roomId: roomId, roomName: roomName,
            model: "yeelink.light.lamp4", isOnline: true,
            kind: .light(LightSpec(entityId: "light.\(id)", isOn: isOn))
        )
    }

    static let rooms = [
        RoomArea(id: "study", name: "书房", sortOrder: 0),
        RoomArea(id: "bedroom", name: "主卧", sortOrder: 1),
        RoomArea(id: "kitchen", name: "厨房", sortOrder: 2)
    ]
    static let studyCeiling = light("dev_study_ceiling", "书房吸顶灯", roomId: "study", roomName: "书房", isOn: true)
    static let studyDesk = light("dev_study_desk", "书房台灯", roomId: "study", roomName: "书房", isOn: true)
    static let bedroomLamp = light("dev_bedroom_lamp", "主卧床头灯", roomId: "bedroom", roomName: "主卧", isOn: true)
    static let kitchenLight = light("dev_kitchen_light", "厨房灯", roomId: "kitchen", roomName: "厨房", isOn: false)

    static func makeStore(
        _ devices: [SmartDevice] = [studyCeiling, studyDesk, bedroomLamp, kitchenLight]
    ) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(rooms: rooms, devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.bare.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (store, mock)
    }

    @Test("关灯 with several lights on asks with chips and runs nothing")
    func severalOnAsks() async throws {
        let (store, mock) = try await Self.makeStore()
        let plan = try #require(await store.runAssistantCommand("关灯"))

        #expect(plan.intents.isEmpty)
        #expect(store.assistantState == .awaitingChoice("开着：书房吸顶灯、书房台灯、主卧床头灯。请说出房间或设备名"))
        #expect(store.assistantSuggestions.map(\.title) == [
            "关闭书房吸顶灯",
            "关闭书房台灯",
            "关闭主卧床头灯",
            "全部关掉"
        ])
        #expect(await mock.executedCommands.isEmpty)
        #expect(store.scheduledCommands.isEmpty)
        #expect(store.devices.filter(\.isActiveOn).count == 3)
    }

    @Test("全部关掉 runs every lit light, offers undo, and undo restores them")
    func allOffChoiceRunsAndUndoes() async throws {
        let (store, mock) = try await Self.makeStore()
        _ = await store.runAssistantCommand("关灯")
        let allOff = try #require(store.assistantSuggestions.last)
        #expect(allOff.title == "全部关掉")

        await store.applyAssistantSuggestion(allOff)
        let executed = await mock.executedCommands
        #expect(executed.count == 3)
        #expect(store.devices.filter(\.isActiveOn).isEmpty)
        #expect(store.undoBanner?.restoreCommands.count == 3)

        let undo = try #require(store.undoTurnAllOff())
        await undo.value
        #expect(store.devices.filter(\.isActiveOn).map(\.id) == [
            "dev_study_ceiling",
            "dev_study_desk",
            "dev_bedroom_lamp"
        ])
        let restored = await mock.executedCommands
        #expect(restored.dropFirst(3).allSatisfy { command in
            if case .setLightPower(_, let on) = command { return on }
            return false
        })
    }

    @Test("关灯 with every light off answers instead of touching a dark light")
    func nothingOnAnswers() async throws {
        let allOff = [
            Self.studyCeiling.off(), Self.studyDesk.off(),
            Self.bedroomLamp.off(), Self.kitchenLight
        ]
        let (store, mock) = try await Self.makeStore(allOff)
        let plan = try #require(await store.runAssistantCommand("关灯"))

        #expect(plan.intents.isEmpty)
        #expect(store.assistantState == .done("灯都关着"))
        #expect(store.assistantSuggestions.isEmpty)
        #expect(await mock.executedCommands.isEmpty)
    }

    @Test("A room the panel shows decides which lit lights a bare 关灯 closes")
    func panelRoomDecides() async throws {
        let (store, mock) = try await Self.makeStore()
        #expect(store.selectRoom("study"))
        #expect(store.panelRoomName == "书房")

        let plan = try #require(await store.runAssistantCommand("关灯"))
        #expect(plan.intents.map(\.targetId) == ["dev_study_ceiling", "dev_study_desk"])
        let executed = await mock.executedCommands
        #expect(executed.count == 2)
        #expect(store.devices.first { $0.id == "dev_bedroom_lamp" }?.isActiveOn == true)
        #expect(store.undoBanner?.restoreCommands.count == 2)
    }

    @Test("A delayed bare 关灯 resolves against the panel room when the timer is set")
    func delayedCommandResolvesWhenScheduled() async throws {
        let (store, mock) = try await Self.makeStore()
        #expect(store.selectRoom("study"))
        store.assistantSleep = { _ in try await Task.sleep(for: .milliseconds(60)) }

        let plan = try #require(await store.runAssistantCommand("10分钟后关灯"))
        #expect(plan.intents.map(\.targetId) == ["dev_study_ceiling", "dev_study_desk"])
        #expect(store.scheduledCommands.count == 1)
        #expect(await mock.executedCommands.isEmpty)

        store.selectRoom(nil)
        for _ in 0..<50 where !store.scheduledCommands.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.scheduledCommands.isEmpty)
        let executed = await mock.executedCommands
        #expect(executed.count == 2)
        #expect(store.devices.first { $0.id == "dev_bedroom_lamp" }?.isActiveOn == true)
    }
}

private extension SmartDevice {
    func off() -> SmartDevice {
        var copy = self
        if case .light(var spec) = copy.kind {
            spec.isOn = false
            copy.kind = .light(spec)
        }
        return copy
    }
}
