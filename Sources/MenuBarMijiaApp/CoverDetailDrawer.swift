import MijiaCore
import SwiftUI

/// Position, open/stop/close, battery and fault for a cover (window opener or curtain). Kept out
/// of `DeviceCardView` so that file stays under the line-count gate (#184).
struct CoverDetailDrawer: View {
    let device: SmartDevice
    let spec: CoverSpec
    let store: HomeStore
    let accent: Color
    let statusColor: Color

    var body: some View {
        let position = Double(spec.positionPercent ?? 0)
        VStack(alignment: .leading, spacing: 8) {
            if let fault = spec.faultText, !fault.isEmpty {
                Text(fault)
                    .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if spec.positionWritable {
                LiquidGlassSlider(
                    value: Binding(
                        get: { position },
                        set: { store.setCoverPosition(device.id, percent: Int($0.rounded())) }
                    ),
                    in: 0...100,
                    step: 1,
                    iconName: "window.vertical.open",
                    iconColor: statusColor,
                    trackFill: LinearGradient(
                        colors: [accent.opacity(0.55), accent.opacity(0.92)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    formattedValue: "\(Int(position))%"
                )
                .disabled(!device.isOnline)
            }
            if spec.canMove || spec.batteryPercent != nil {
                HStack(spacing: 8) {
                    if let open = spec.openDescription {
                        motorButton(open)
                    }
                    if let pause = spec.pauseDescription {
                        motorButton(pause)
                    }
                    if let close = spec.closeDescription {
                        motorButton(close)
                    }
                    if let battery = spec.batteryPercent {
                        Spacer(minLength: 0)
                        Text(L10n.tr("电量 \(battery)%", "Battery \(battery)%"))
                            .font(.system(size: DesignTokens.TypeSize.caption, weight: .medium))
                            .foregroundStyle(statusColor)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func motorButton(_ description: String) -> some View {
        Button(Self.actionTitle(description)) {
            store.setCoverMotor(device.id, description: description)
        }
        .buttonStyle(PillActionButtonStyle())
        .disabled(!device.isOnline)
    }

    private static func actionTitle(_ description: String) -> String {
        switch description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "open", "打开": return L10n.tr("打开", "Open")
        case "close", "关闭": return L10n.tr("关闭", "Close")
        case "pause", "stop", "暂停": return L10n.tr("暂停", "Pause")
        default: return description
        }
    }
}
