import Foundation
import Testing
@testable import MijiaCore

/// #280: Home Assistant `cover.*` entities join the same CoverDevice model and card as MIoT
/// curtains. The fixture carries every Home Assistant `device_class`, the name fallback used when
/// no class is set, and a cover that only supports open / stop / close without a position slider.
struct HACoverDeviceTests {
    private struct FixtureState: Decodable {
        let entityId: String
        let state: String
        let attributes: [String: JSONValue]?

        enum CodingKeys: String, CodingKey {
            case entityId = "entity_id"
            case state
            case attributes
        }
    }

    private struct Fixture: Decodable {
        let areas: [HAAreaEntry]
        let devices: [HADeviceEntry]
        let entities: [HAEntityEntry]
        let states: [FixtureState]
    }

    private enum FixtureError: Error {
        case missing
        case notACover
    }

    // MARK: - Fixtures

    private func fixtureURL(_ relativePath: String) throws -> URL {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Linux copies test sources into scripts/linux-check/.work; fixtures stay at the repo root.
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw FixtureError.missing
    }

    private func coverHome() throws -> SynthesizedHome {
        let data = try Data(contentsOf: try fixtureURL("Tests/Fixtures/ha_cover_snapshot.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let states = Dictionary(uniqueKeysWithValues: fixture.states.map { state in
            (state.entityId, HAEntityState(
                entityId: state.entityId,
                state: state.state,
                attributes: state.attributes ?? [:]
            ))
        })
        return DeviceSynthesizer.synthesize(
            areas: fixture.areas,
            devices: fixture.devices,
            entities: fixture.entities,
            states: states
        )
    }

    private func miCurtainHome() throws -> SynthesizedHome {
        let url = try fixtureURL("Tests/Fixtures/miot/lumi.curtain.hagl05.json")
        let spec = try JSONDecoder().decode(MiotDeviceSpec.self, from: Data(contentsOf: url))
        let record = MiDeviceRecord(did: "curtain1", name: "客厅窗帘", model: "lumi.curtain.hagl05", isOnline: true)
        let values: [MiotPropKey: JSONValue] = [
            .init(did: "curtain1", siid: 2, piid: 6): .number(0),
            .init(did: "curtain1", siid: 2, piid: 3): .number(60),
            .init(did: "curtain1", siid: 2, piid: 7): .number(60),
        ]
        return MiotSynthesizer.synthesize(
            devices: [record], rooms: [], specs: [record.model: spec], values: values
        )
    }

    private func coverSpec(_ deviceId: String, in home: SynthesizedHome) throws -> CoverSpec {
        let device = try #require(home.devices.first { $0.id == deviceId })
        guard case .cover(let spec) = device.kind else {
            Issue.record("\(deviceId) was not synthesized as a cover")
            throw FixtureError.notACover
        }
        return spec
    }

    @MainActor
    private func makeStore(_ home: SynthesizedHome) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: home)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.hacover.\(UUID().uuidString)")
        store.controlDebounceInterval = .zero
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.devices.count == home.devices.count)
        return (store, mock)
    }

    // MARK: - Synthesis

    @Test("Every Home Assistant cover device_class maps to its CoverDevice subtype")
    func deviceClassSubtypes() throws {
        let home = try coverHome()
        let expected: [(id: String, subtype: CoverSubtype)] = [
            ("cover-curtain", .curtain),
            ("cover-blind", .curtain),
            ("cover-shade", .curtain),
            ("cover-shutter", .curtain),
            ("cover-awning", .curtain),
            ("cover-damper", .curtain),
            ("cover-window", .windowOpener),
            ("cover-garage", .garageDoor),
            ("cover-garage-open", .garageDoor),
            ("cover-gate", .garageDoor),
            ("cover-door", .garageDoor),
        ]
        for row in expected {
            #expect(try coverSpec(row.id, in: home).subtype == row.subtype, "\(row.id)")
        }
    }

    @Test("A cover without device_class infers its subtype from the name, defaulting to a window opener")
    func nameInference() throws {
        let home = try coverHome()
        let expected: [(id: String, subtype: CoverSubtype)] = [
            ("cover-name-curtain-cn", .curtain),
            ("cover-name-blind-en", .curtain),
            ("cover-name-garage-cn", .garageDoor),
            ("cover-name-gate-en", .garageDoor),
            ("cover-name-window-cn", .windowOpener),
            ("cover-name-window-en", .windowOpener),
            ("cover-name-unknown", .windowOpener),
        ]
        for row in expected {
            #expect(try coverSpec(row.id, in: home).subtype == row.subtype, "\(row.id)")
        }
    }

    @Test("Covers report position and motion, and only position-capable covers expose a slider")
    func positionAndMotion() throws {
        let home = try coverHome()

        let curtain = try coverSpec("cover-curtain", in: home)
        #expect(curtain.entityId == "cover.living_curtain")
        #expect(curtain.positionPercent == 60)
        #expect(curtain.positionWritable)
        #expect(curtain.openDescription == "open")
        #expect(curtain.closeDescription == "close")
        #expect(curtain.pauseDescription == "stop")
        #expect(curtain.motion == .stopped)

        let blind = try coverSpec("cover-blind", in: home)
        #expect(blind.positionPercent == 25)
        #expect(blind.motion == .opening)

        let door = try coverSpec("cover-door", in: home)
        #expect(door.positionPercent == 0, "open/closed is still a usable tap direction without a position reading")
        #expect(!door.positionWritable)
        #expect(door.canMove)
        #expect(door.pauseDescription != nil)

        let doorDevice = try #require(home.devices.first { $0.id == "cover-door" })
        #expect(doorDevice.hasDetailDrawer)
    }

    // MARK: - Confirmation

    @Test("Garage doors and gates confirm open and close; curtains run directly")
    @MainActor
    func confirmationBySubtype() async throws {
        let home = try coverHome()
        let (store, mock) = try await makeStore(home)

        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        let closedGarage = try #require(store.devices.first { $0.id == "cover-garage" })
        let openGarage = try #require(store.devices.first { $0.id == "cover-garage-open" })
        let gate = try #require(store.devices.first { $0.id == "cover-gate" })

        #expect(store.togglePrimary(closedGarage) == nil)
        #expect(store.togglePrimary(openGarage) == nil)
        #expect(store.togglePrimary(gate) == nil)
        #expect(prompts == 3)
        #expect(await mock.executedCommands.isEmpty)

        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return true
        }
        #expect(await store.togglePrimary(closedGarage)?.value == true)
        #expect(await mock.executedCommands.contains(
            .setSelectOption(entityId: "cover.left_garage", option: "open")
        ))
        #expect(await store.togglePrimary(openGarage)?.value == true)
        #expect(await mock.executedCommands.contains(
            .setSelectOption(entityId: "cover.right_garage", option: "close")
        ))

        let curtain = try #require(store.devices.first { $0.id == "cover-curtain-closed" })
        let before = prompts
        #expect(await store.togglePrimary(curtain)?.value == true)
        #expect(prompts == before)
        #expect(await mock.executedCommands.contains(
            .setSelectOption(entityId: "cover.guest_curtain", option: "open")
        ))
    }

    // MARK: - Card tap

    @Test("A Home Assistant curtain card taps closed to open, open to close, and moving to stop")
    @MainActor
    func curtainTapDirections() async throws {
        let home = try coverHome()
        let (store, mock) = try await makeStore(home)

        let closed = try #require(store.devices.first { $0.id == "cover-curtain-closed" })
        #expect(await store.togglePrimary(closed)?.value == true)
        #expect(await mock.executedCommands == [
            .setSelectOption(entityId: "cover.guest_curtain", option: "open"),
        ])

        let moving = try #require(store.devices.first { $0.id == "cover-curtain-moving" })
        #expect(await store.togglePrimary(moving)?.value == true)
        #expect(await mock.executedCommands.last == .setSelectOption(entityId: "cover.master_curtain", option: "stop"))

        let open = try #require(store.devices.first { $0.id == "cover-curtain" })
        #expect(await store.togglePrimary(open)?.value == true)
        #expect(await mock.executedCommands.last == .setSelectOption(entityId: "cover.living_curtain", option: "close"))
    }

    // MARK: - Commands

    @Test("Home Assistant covers dispatch cover services instead of select or number services")
    func commandMapping() {
        let open = HAWebSocketProvider.mapCommandToService(
            .setSelectOption(entityId: "cover.living_curtain", option: "open")
        )
        #expect(open.domain == "cover")
        #expect(open.service == "open_cover")
        #expect(open.payload["entity_id"] as? String == "cover.living_curtain")

        let close = HAWebSocketProvider.mapCommandToService(
            .setSelectOption(entityId: "cover.living_curtain", option: "close")
        )
        #expect(close.domain == "cover")
        #expect(close.service == "close_cover")

        let stop = HAWebSocketProvider.mapCommandToService(
            .setSelectOption(entityId: "cover.living_curtain", option: "stop")
        )
        #expect(stop.domain == "cover")
        #expect(stop.service == "stop_cover")

        let position = HAWebSocketProvider.mapCommandToService(
            .setNumberValue(entityId: "cover.living_curtain", value: 37)
        )
        #expect(position.domain == "cover")
        #expect(position.service == "set_cover_position")
        #expect(position.payload["position"] as? Double == 37)
    }

    // MARK: - Dual source

    @Test("A Home Assistant curtain and the same Mijia motor show only one card")
    func dualSourceDeduplicates() throws {
        let haHome = try coverHome()
        let haCurtain = try #require(haHome.devices.first { $0.id == "cover-curtain" })
        let identity = try #require(haHome.deviceIdentities[haCurtain.id])
        var ha = SynthesizedHome(devices: [haCurtain])
        ha.deviceIdentities = [haCurtain.id: identity]

        let merged = DeviceDeduplicator.merge(
            homeAssistant: ha,
            xiaomiCloud: try miCurtainHome()
        )

        #expect(merged.home.devices.count == 1)
        let card = try #require(merged.home.devices.first)
        guard case .cover = card.kind else {
            Issue.record("the merged card lost the curtain")
            return
        }
        #expect(merged.routes[card.id] != nil)
    }
}
