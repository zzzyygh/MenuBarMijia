import Foundation

/// Favorites in `favoriteOrder`, then rooms, scenes, and remaining devices; trimmed, deduped, capped at `maximumCount`.
public enum SpeechRecognitionHints {
    public static let maximumCount = 100

    public static func contextualStrings(
        devices: [SmartDevice],
        rooms: [RoomArea],
        scenes: [HomeScene],
        favoriteOrder: [String]
    ) -> [String] {
        let devicesById = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String] = []
        var seen = Set<String>()

        func append(_ name: String) {
            guard names.count < maximumCount else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            names.append(trimmed)
        }

        for id in favoriteOrder {
            if let device = devicesById[id] { append(device.name) }
        }
        for room in rooms { append(room.name) }
        for scene in scenes { append(scene.name) }
        for device in devices { append(device.name) }
        return names
    }
}
