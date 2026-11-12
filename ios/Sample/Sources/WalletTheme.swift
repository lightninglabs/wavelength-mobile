import SwiftUI
import UIKit

enum WalletTheme {
    static let background = color(light: 0xFAFAFB, dark: 0x090A0C)
    static let foreground = color(light: 0x151518, dark: 0xF4F4F0)
    static let secondary = color(light: 0x72757C, dark: 0xA7AAAD)
    static let surface = color(light: 0xF0F0F3, dark: 0x17191D)
    static let line = color(light: 0xE4E5E8, dark: 0x2B2D31)
    static let action = color(light: 0x151518, dark: 0xD6FF5F)
    static let actionText = color(light: 0xFFFFFF, dark: 0x090A0C)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

struct WalletLoadingIndicator: View {
    var label = "Loading"

    var body: some View {
        ProgressView()
            .tint(WalletTheme.secondary)
            .accessibilityLabel(label)
    }
}

struct WalletButtonStyle: ButtonStyle {
    var secondary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(secondary ? WalletTheme.foreground : WalletTheme.actionText)
            .background(secondary ? WalletTheme.surface : WalletTheme.action,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 15))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.38)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct WalletPage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28, content: content)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(WalletTheme.background.ignoresSafeArea())
        .foregroundStyle(WalletTheme.foreground)
    }
}

struct WalletAmount: View {
    let amount: Int64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            number
            Text("sats").font(.title2).foregroundStyle(WalletTheme.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .accessibilityElement(children: .combine)
        .privacySensitive()
    }

    @ViewBuilder private var number: some View {
        let text = Text(WalletFormatting.satoshis.string(from: NSNumber(value: amount)) ?? "0")
            .font(.system(size: 54, weight: .regular))
            .tracking(-2)
        if #available(iOS 17.0, *), !reduceMotion {
            text.contentTransition(.numericText(value: Double(amount)))
                .animation(.easeInOut(duration: 0.3), value: amount)
        } else {
            text
        }
    }
}

struct WalletStatus: View {
    let text: String
    var pending = false
    var complete = false
    var failed = false
    var textStyle: Font = .body.weight(.medium)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            if pending {
                if reduceMotion {
                    Image(systemName: "clock")
                } else {
                    ProgressView().tint(WalletTheme.secondary)
                }
            } else if complete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(WalletTheme.action)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.7).combined(with: .opacity))
            } else if failed {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
            Text(text).font(textStyle)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: complete)
        .accessibilityElement(children: .combine)
    }
}

struct WalletField<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).foregroundStyle(WalletTheme.secondary)
            content()
                .padding(15)
                .background(WalletTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct WalletDivider: View {
    var body: some View { Rectangle().fill(WalletTheme.line).frame(height: 0.5) }
}

enum WalletFeedback {
    static func completed() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
