import Foundation

extension HomeStore {
    static let defaultDoorbellPopupSeconds = 60
    public static let doorbellPopupSecondsRange = 15...300
    static let recentDoorbellRingLimit = 20

    /// Records every press once, then opens the doorbell's camera only when the user turned that on,
    /// the screen-lock rule allows it, and the ringing device has an online camera card (#308).
    func handleDoorbellRing(_ ring: DoorbellRing) {
        guard handledDoorbellRingKeys.insert(ring.key).inserted else { return }
        recentDoorbellRings.insert(ring, at: 0)
        if recentDoorbellRings.count > Self.recentDoorbellRingLimit {
            recentDoorbellRings.removeLast(recentDoorbellRings.count - Self.recentDoorbellRingLimit)
        }
        guard doorbellAutoPopup, !isControlBlockedByScreenLock,
              let device = devices.first(where: { $0.id == ring.deviceId }),
              device.isOnline, case .camera = device.kind else { return }
        let seconds = min(max(doorbellPopupSeconds, Self.doorbellPopupSecondsRange.lowerBound), Self.doorbellPopupSecondsRange.upperBound)
        onDoorbellPopup?(DoorbellPopup(deviceId: device.id, playsChime: doorbellChime, dismissAfter: .seconds(seconds)))
    }
}
