import Foundation

/// GLOSSARY `BareCategoryCommand`: a command that names only a device category ("关灯",
/// "turn off the lights") with no room, device name, or scope word. Closing looks at what is on
/// right now: nothing on gets an honest answer, one device runs directly, and several use the room
/// the panel shows or wait for a tap on a candidate.
public enum BareCategoryCommand {
    public static let candidateLimit = 4

    public enum Resolution: Equatable, Sendable {
        /// Nothing of the category is on; `room` is set when the panel's room had none on.
        case none(room: String?)
        /// Run these now: the only device on, or every device on in the panel's room.
        case run([SmartDevice])
        /// Several are on and no room decides: offer these, most used first.
        case candidates([SmartDevice])
    }

    public static func resolve(
        active: [SmartDevice],
        panelRoomName: String?,
        usageOrder: [String] = []
    ) -> Resolution {
        guard !active.isEmpty else { return .none(room: nil) }
        if active.count == 1 { return .run(active) }
        if let room = panelRoomName, !room.isEmpty {
            let inRoom = active.filter { $0.roomName == room }
            return inRoom.isEmpty ? .none(room: room) : .run(inRoom)
        }
        return .candidates(ranked(active, by: usageOrder))
    }

    /// Habit order first, catalog order for everything the user has not used yet.
    static func ranked(_ devices: [SmartDevice], by usageOrder: [String]) -> [SmartDevice] {
        guard !usageOrder.isEmpty else { return devices }
        let rank = Dictionary(usageOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return devices.enumerated()
            .sorted { left, right in
                let leftRank = rank[left.element.id] ?? Int.max
                let rightRank = rank[right.element.id] ?? Int.max
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }
            .map(\.element)
    }

    public static func answerReply(category: IntentDeviceCategory, room: String?) -> String {
        let noun = category.spokenNoun
        guard let room else {
            return L10n.format("%@都关着", "The %@ are all off", noun)
        }
        return L10n.format(
            "%@的%@都关着",
            "The %@ %@ are all off",
            L10n.displayRoomName(room),
            noun
        )
    }

    /// What a headless entry (Shortcut, URL) can say instead of running something ambiguous.
    public static func choiceReply(_ devices: [SmartDevice]) -> String {
        let separator = L10n.isEnglish ? ", " : "、"
        return L10n.format(
            "开着：%@。请说出房间或设备名",
            "On: %@. Say a room or device name",
            devices.map(\.name).joined(separator: separator)
        )
    }

    /// Up to `candidateLimit` device chips plus one that closes every device still on.
    public static func suggestions(
        candidates: [SmartDevice],
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> [AssistantSuggestion] {
        var chips: [AssistantSuggestion] = []
        for device in candidates.prefix(candidateLimit) {
            let intent = DeviceIntent(targetId: device.id, operation: .power(false))
            guard let title = UserHabitMemory.suggestionTitle(for: intent, devices: devices, scenes: scenes) else {
                continue
            }
            chips.append(AssistantSuggestion(id: "bare:off:\(device.id)", title: title, intents: [intent]))
        }
        let allOff = candidates.map { DeviceIntent(targetId: $0.id, operation: .power(false)) }
        chips.append(AssistantSuggestion(
            id: "bare:off:all",
            title: L10n.tr("全部关掉", "Turn All Off"),
            intents: allOff
        ))
        return chips
    }
}

extension IntentDeviceCategory {
    /// Noun used when a bare-category answer says what is already off ("灯都关着").
    public var spokenNoun: String {
        switch self {
        case .light: return L10n.tr("灯", "lights")
        case .climate: return L10n.tr("空调", "air conditioners")
        case .heater: return L10n.tr("电暖器", "heaters")
        case .fan: return L10n.tr("风扇", "fans")
        case .airPurifier: return L10n.tr("空气净化器", "air purifiers")
        case .dehumidifier: return L10n.tr("除湿机", "dehumidifiers")
        case .diffuser: return L10n.tr("香氛机", "diffusers")
        case .plug: return L10n.tr("插座", "plugs")
        case .vacuum: return L10n.tr("扫地机", "robot vacuums")
        case .speaker: return L10n.tr("音箱", "speakers")
        case .tv: return L10n.tr("电视", "TVs")
        case .fridge: return L10n.tr("冰箱", "fridges")
        case .camera: return L10n.tr("摄像机", "cameras")
        case .sensor: return L10n.tr("传感器", "sensors")
        case .cover: return L10n.tr("窗帘", "covers")
        }
    }
}
