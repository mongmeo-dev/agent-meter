import AgentMeterCore
import AppKit
import CoreText
import SwiftUI

// Tokens follow DESIGN.md (Raycast analysis from VoltAgent/awesome-design-md). The type scale
// is compressed for a menu bar popover; the marketing scale in DESIGN.md is too large here.

enum AppResources {
  /// SwiftPM resources live in `AgentMeter_AgentMeter.bundle`, which the packaged app copies
  /// into `Contents/Resources` instead of the location `Bundle.module` expects.
  static let bundle: Bundle? = {
    if Bundle.main.bundleURL.pathExtension == "app" {
      return Bundle.main.resourceURL
        .flatMap { Bundle(url: $0.appendingPathComponent("AgentMeter_AgentMeter.bundle")) }
    }
    return Bundle.module
  }()
}

enum AMColor {
  static let canvas = Color(hex: 0x07080A)
  static let surface = Color(hex: 0x0D0D0D)
  static let surfaceElevated = Color(hex: 0x101111)
  static let surfaceCard = Color(hex: 0x121212)
  static let hairline = Color(hex: 0x242728)
  static let hairlineStrong = Color.white.opacity(0.16)

  static let ink = Color(hex: 0xF4F4F6)
  static let body = Color(hex: 0xCDCDCD)
  static let mute = Color(hex: 0x9C9C9D)
  static let ash = Color(hex: 0x6A6B6C)
  static let stone = Color(hex: 0x434345)

  static let primary = Color.white
  static let primaryPressed = Color(hex: 0xE8E8E8)
  static let onPrimary = Color.black

  // DESIGN.md keeps accents out of chrome; agent-meter deliberately uses them for meter
  // levels and provider status only.
  static let accentGreen = Color(hex: 0x59D499)
  static let accentYellow = Color(hex: 0xFFC533)
  static let accentRed = Color(hex: 0xFF6161)

  static func meter(_ level: RemainingLevel) -> Color {
    switch level {
    case .normal: ink
    case .low: accentYellow
    case .critical: accentRed
    }
  }
}

enum AMRadius {
  static let xs: CGFloat = 4
  static let sm: CGFloat = 6
  static let md: CGFloat = 8
  static let lg: CGFloat = 10
}

enum AMFont {
  enum Weight: String {
    case regular = "Inter-Regular"
    case medium = "Inter-Medium"
    case semibold = "Inter-SemiBold"

    var system: Font.Weight {
      switch self {
      case .regular: .regular
      case .medium: .medium
      case .semibold: .semibold
      }
    }
  }

  static func registerBundledFonts() {
    for weight in [Weight.regular, .medium, .semibold] {
      guard let url = AppResources.bundle?.url(forResource: weight.rawValue, withExtension: "ttf")
      else { continue }
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
  }

  /// Inter with the `ss03` stylistic set DESIGN.md requires. Hangul falls back to the system
  /// font through the default cascade list.
  static func inter(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
    let features: [[NSFontDescriptor.FeatureKey: Any]] = [
      [
        NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureTag as String): "ss03",
        NSFontDescriptor.FeatureKey(rawValue: kCTFontOpenTypeFeatureValue as String): 1,
      ]
    ]
    let descriptor = NSFontDescriptor(name: weight.rawValue, size: size)
      .addingAttributes([.featureSettings: features])
    guard let font = NSFont(descriptor: descriptor, size: size),
      font.fontName == weight.rawValue
    else {
      return .system(size: size, weight: weight.system)
    }
    return Font(font as CTFont)
  }
}

enum AMMotion {
  /// kinetics.colorion.co "Elastic Progress" spring (stiffness 200, damping 20).
  static let meterFill = Animation.interpolatingSpring(stiffness: 200, damping: 20)
  /// kinetics.colorion.co "Odometer Count-up": 1.4s ease-out cubic.
  static let countUp = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 1.4)
  /// kinetics.colorion.co "Stagger Entrance": 0.45s cubic-bezier(.16,1,.3,1), 90ms apart.
  static func entrance(index: Int) -> Animation {
    .timingCurve(0.16, 1, 0.3, 1, duration: 0.45).delay(Double(index) * 0.09)
  }
  static let disclosure = Animation.spring(response: 0.32, dampingFraction: 0.86)
}

extension Color {
  init(hex: UInt32) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

extension View {
  /// `store-extension-card`: surface, 1px hairline, no shadow.
  func amCard(padding: CGFloat = 14) -> some View {
    self
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(AMColor.surface, in: RoundedRectangle(cornerRadius: AMRadius.lg))
      .overlay(
        RoundedRectangle(cornerRadius: AMRadius.lg)
          .strokeBorder(AMColor.hairline, lineWidth: 1))
  }

  /// Rises and fades in on appear, one card after another.
  func amEntrance(index: Int, isVisible: Bool, reduceMotion: Bool) -> some View {
    self
      .opacity(isVisible ? 1 : 0)
      .offset(y: isVisible || reduceMotion ? 0 : 14)
      .animation(reduceMotion ? nil : AMMotion.entrance(index: index), value: isVisible)
  }
}

struct AMHairline: View {
  var body: some View {
    Rectangle()
      .fill(AMColor.hairline)
      .frame(height: 1)
  }
}

/// Remaining-quota meter whose fill springs to its value and tints when low.
struct AMMeterBar: View {
  let value: Double
  let level: RemainingLevel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown: Double = 0

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(AMColor.surfaceCard)
        Capsule()
          .fill(AMColor.meter(level))
          .frame(width: proxy.size.width * min(1, max(0, shown / 100)))
      }
    }
    .frame(height: 4)
    .overlay(Capsule().strokeBorder(AMColor.hairline.opacity(0.6), lineWidth: 0.5))
    .onAppear { update(to: value) }
    .onChange(of: value) { _, newValue in update(to: newValue) }
    .accessibilityHidden(true)
  }

  private func update(to newValue: Double) {
    guard !reduceMotion else {
      shown = newValue
      return
    }
    withAnimation(AMMotion.meterFill) { shown = newValue }
  }
}

/// Percentage that counts up from zero on appear and eases between refreshes.
struct AMCountingPercent: View {
  let value: Double
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown: Double = 0

  var body: some View {
    CountingText(value: shown)
      .onAppear { update(to: value) }
      .onChange(of: value) { _, newValue in update(to: newValue) }
  }

  private func update(to newValue: Double) {
    guard !reduceMotion else {
      shown = newValue
      return
    }
    withAnimation(AMMotion.countUp) { shown = newValue }
  }

  private struct CountingText: View, Animatable {
    var value: Double

    nonisolated var animatableData: Double {
      get { value }
      set { value = newValue }
    }

    var body: some View {
      Text("\(Int(value.rounded()))%")
        .font(AMFont.inter(13, .semibold))
        .monospacedDigit()
        .foregroundStyle(AMColor.ink)
    }
  }
}

/// `badge-pro` chip with a status dot that morphs between provider phases.
struct AMStatusPill: View {
  let phase: ProviderPhase

  var body: some View {
    HStack(spacing: 5) {
      if phase == .loading {
        AMSpinner()
      } else {
        Circle()
          .fill(dotColor)
          .frame(width: 6, height: 6)
      }
      Text(label)
        .contentTransition(.opacity)
    }
    .font(AMFont.inter(11, .medium))
    .foregroundStyle(Color.white.opacity(0.72))
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(AMColor.surfaceElevated, in: RoundedRectangle(cornerRadius: AMRadius.xs))
    .overlay(
      RoundedRectangle(cornerRadius: AMRadius.xs)
        .strokeBorder(AMColor.hairline, lineWidth: 1))
    .animation(AMMotion.disclosure, value: phase)
  }

  private var label: String {
    switch phase {
    case .loading: "확인 중"
    case .ready: "정상"
    case .unavailable: "정보 없음"
    case .failed: "오류"
    case .awaitingConsent: "동의 필요"
    }
  }

  private var dotColor: Color {
    switch phase {
    case .ready: AMColor.accentGreen
    case .failed: AMColor.accentRed
    case .loading, .unavailable, .awaitingConsent: AMColor.ash
    }
  }
}

struct AMSpinner: View {
  var size: CGFloat = 8
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var rotating = false

  var body: some View {
    Circle()
      .trim(from: 0, to: 0.7)
      .stroke(AMColor.mute, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      .frame(width: size, height: size)
      .rotationEffect(.degrees(rotating ? 360 : 0))
      .animation(
        reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false),
        value: rotating
      )
      .onAppear { rotating = true }
  }
}

/// `button-primary`: the single white action.
struct AMPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(AMFont.inter(13, .medium))
      .foregroundStyle(AMColor.onPrimary)
      .padding(.horizontal, 14)
      .frame(height: 30)
      .background(
        configuration.isPressed ? AMColor.primaryPressed : AMColor.primary,
        in: RoundedRectangle(cornerRadius: AMRadius.md))
      .contentShape(RoundedRectangle(cornerRadius: AMRadius.md))
  }
}

/// `button-tertiary`: soft surface button for secondary actions.
struct AMTertiaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(AMFont.inter(12, .medium))
      .foregroundStyle(isEnabled ? AMColor.ink : AMColor.ash)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(
        configuration.isPressed ? AMColor.surfaceCard : AMColor.surfaceElevated,
        in: RoundedRectangle(cornerRadius: AMRadius.sm))
      .overlay(
        RoundedRectangle(cornerRadius: AMRadius.sm)
          .strokeBorder(AMColor.hairline, lineWidth: 1))
      .contentShape(RoundedRectangle(cornerRadius: AMRadius.sm))
  }
}

/// Square tertiary button for a single SF Symbol.
struct AMIconButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(isEnabled ? AMColor.ink : AMColor.ash)
      .frame(width: 26, height: 26)
      .background(
        configuration.isPressed ? AMColor.surfaceCard : AMColor.surfaceElevated,
        in: RoundedRectangle(cornerRadius: AMRadius.sm))
      .overlay(
        RoundedRectangle(cornerRadius: AMRadius.sm)
          .strokeBorder(AMColor.hairline, lineWidth: 1))
      .contentShape(RoundedRectangle(cornerRadius: AMRadius.sm))
  }
}

/// `text-input`: elevated surface whose hairline brightens on focus.
struct AMTextFieldStyle: TextFieldStyle {
  @FocusState private var focused: Bool

  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .font(AMFont.inter(12))
      .foregroundStyle(AMColor.ink)
      .focused($focused)
      .padding(.horizontal, 8)
      .frame(height: 26)
      .background(AMColor.surfaceElevated, in: RoundedRectangle(cornerRadius: AMRadius.sm))
      .overlay(
        RoundedRectangle(cornerRadius: AMRadius.sm)
          .strokeBorder(focused ? AMColor.hairlineStrong : AMColor.hairline, lineWidth: 1))
  }
}

/// Collapsible section whose chevron turns and content fades in when expanded.
struct AMDisclosure<Content: View>: View {
  let title: String
  var systemImage: String?
  @ViewBuilder let content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(reduceMotion ? nil : AMMotion.disclosure) { expanded.toggle() }
      } label: {
        HStack(spacing: 8) {
          if let systemImage {
            Image(systemName: systemImage)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(AMColor.mute)
              .frame(width: 16)
          }
          Text(title)
            .font(AMFont.inter(13, .medium))
            .foregroundStyle(AMColor.ink)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AMColor.ash)
            .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(expanded ? "펼침" : "접힘")

      if expanded {
        content()
          .padding(.top, 12)
          .transition(.opacity.combined(with: .offset(y: -4)))
      }
    }
  }
}

/// Label on the left, control on the right, as in a `command-palette-row`.
struct AMSettingRow<Control: View>: View {
  let title: String
  @ViewBuilder let control: () -> Control

  var body: some View {
    HStack(spacing: 12) {
      Text(title)
        .font(AMFont.inter(12))
        .foregroundStyle(AMColor.body)
      Spacer(minLength: 8)
      control()
    }
    .frame(minHeight: 26)
  }
}
