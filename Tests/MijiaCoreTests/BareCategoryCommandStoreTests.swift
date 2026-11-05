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
        try await makeStore(devices, rooms: rooms)
    }

    static func makeStore(
        _ devices: [SmartDevice],
        rooms: [RoomArea]
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
        #expect(store.devices.filter { $0.isActiveOn }.count == 3)
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
        #expect(store.devices.filter { $0.isActiveOn }.isEmpty)
        #expect(store.undoBanner?.restoreCommands.count == 3)

        let undo = try #require(store.undoTurnAllOff())
        await undo.value
        #expect(store.devices.filter { $0.isActiveOn }.map(\.id) == [
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
        #expect(store.assistantSuggestions.contains { $0.id.hasPrefix("bare:off") } == false)
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

    @Test("A delayed bare 关灯 that needs a choice sets no timer, runs nothing, and asks for a room")
    func delayedAmbiguitySchedulesNothing() async throws {
        let (store, mock) = try await Self.makeStore()
        let plan = try #require(await store.runAssistantCommand("10分钟后关灯"))
        #expect(plan.intents.isEmpty)
        #expect(store.scheduledCommands.isEmpty)
        #expect(await mock.executedCommands.isEmpty)
        #expect(store.assistantSuggestions.contains { $0.id == "bare:off:all" } == false)
        guard case .done(let reply) = store.assistantState else {
            Issue.record("expected a done answer, got \(store.assistantState)")
            return
        }
        #expect(reply == "开着：书房吸顶灯、书房台灯、主卧床头灯。请说出房间或设备名")
    }

    @Test("An answer with no lights on replaces the previous bare 关灯 chips")
    func answerClearsStaleChips() async throws {
        let (store, mock) = try await Self.makeStore()
        _ = await store.runAssistantCommand("关灯")
        #expect(store.assistantSuggestions.contains { $0.id == "bare:off:all" })

        let allOff = [
            Self.studyCeiling.off(), Self.studyDesk.off(),
            Self.bedroomLamp.off(), Self.kitchenLight
        ]
        await mock.updateSnapshot(SynthesizedHome(rooms: Self.rooms, devices: allOff))
        for _ in 0..<50 where store.devices.contains(where: \.isActiveOn) {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await store.runAssistantCommand("关灯")
        #expect(store.assistantState == .done("灯都关着"))
        #expect(store.assistantSuggestions.contains { $0.id.hasPrefix("bare:off") } == false)
    }

    @Test("关灯 follows the panel room id, not a shared room name across accounts")
    func panelRoomUsesRoomId() async throws {
        let cnCeiling = Self.light(
            "dev_cn_ceiling", "客厅吸顶灯", roomId: "account-cn/ke_ting", roomName: "客厅", isOn: true
        )
        let deCeiling = Self.light(
            "dev_de_ceiling", "客厅吊灯", roomId: "account-de/ke_ting", roomName: "客厅", isOn: true
        )
        let (store, mock) = try await Self.makeStore(
            [cnCeiling, deCeiling],
            rooms: [
                RoomArea(id: "account-cn/ke_ting", name: "客厅", sortOrder: 0),
                RoomArea(id: "account-de/ke_ting", name: "客厅", sortOrder: 1)
            ]
        )
        #expect(store.selectRoom("account-cn/ke_ting"))
        #expect(store.panelRoom == BareCategoryCommand.Room(id: "account-cn/ke_ting", name: "客厅"))

        let plan = try #require(await store.runAssistantCommand("关灯"))
        #expect(plan.intents.map(\.targetId) == ["dev_cn_ceiling"])
        let executed = await mock.executedCommands
        #expect(executed == [.setLightPower(entityId: "light.dev_cn_ceiling", isOn: false)])
        #expect(store.devices.first { $0.id == "dev_de_ceiling" }?.isActiveOn == true)
    }

    @Test("A delayed bare 关灯 resolves against the panel room when the timer is set")
    func delayedCommandResolvesWhenScheduled() async throws {
        let (store, mock) = try await Self.makeStore()
        #expect(store.selectRoom("study"))
        let gate = AsyncStream.makeStream(of: Void.self)
        store.assistantSleep = { _ in
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
        }

        let plan = try #require(await store.runAssistantCommand("10分钟后关灯"))
        #expect(plan.intents.map(\.targetId) == ["dev_study_ceiling", "dev_study_desk"])
        #expect(store.scheduledCommands.count == 1)
        // The timer is parked inside assistantSleep, so nothing can run before the test releases it.
        #expect(await mock.executedCommands.isEmpty)

        store.selectRoom(nil)
        gate.continuation.finish()
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
