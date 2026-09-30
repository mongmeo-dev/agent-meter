import AgentMeterCore
import AppKit
import Sparkle
import SwiftUI

@main
@MainActor
struct AgentMeterApp: App {
  @StateObject private var model = AgentMeterModel()
  private let updaterController: SPUStandardUpdaterController

  init() {
    AMFont.registerBundledFonts()
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
  }

  var body: some Scene {
    MenuBarExtra {
      AgentMeterMenu(model: model, updater: updaterController.updater)
    } label: {
      Image(nsImage: model.menuBarImage)
        .accessibilityLabel(Text(model.menuBarAccessibilityLabel))
    }
    .menuBarExtraStyle(.window)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("업데이트 확인…") {
          updaterController.updater.checkForUpdates()
        }
      }
    }
  }
}

@MainActor
private final class AgentMeterModel: ObservableObject {
  private static let consentKey = "AgentMeter.credentialsAndNetworkConsent"
  private let service: UsageService
  private var refreshTasks: [Provider: Task<Void, Never>] = [:]
  private var refreshGenerations: [Provider: UInt64] = [:]
  private var automaticTask: Task<Void, Never>?

  @Published private(set) var consentGranted: Bool
  @Published private(set) var refreshInterval: RefreshInterval
  @Published private(set) var menuBarAppearance: MenuBarAppearance
  @Published private(set) var states: [Provider: ProviderState]

  init() {
    self.service = UsageService(store: UserDefaultsUsageRequestStore())
    let granted = UserDefaults.standard.bool(forKey: Self.consentKey)
    self.consentGranted = granted
    self.refreshInterval = RefreshInterval.load()
    self.menuBarAppearance = MenuBarAppearance.load()
    self.states = Dictionary(
      uniqueKeysWithValues: Provider.allCases.map {
        ($0, ProviderState(provider: $0, phase: granted ? .loading : .awaitingConsent))
      })

    if granted {
      Task { [weak self] in
        guard let self else { return }
        await self.service.setConsent(true)
        self.restartAutomaticRefresh()
        self.refreshAll()
      }
    }
  }

  var isRefreshing: Bool { !refreshTasks.isEmpty }

  func setRefreshInterval(_ interval: RefreshInterval) {
    guard refreshInterval != interval else { return }
    refreshInterval = interval
    interval.save()
    restartAutomaticRefresh()
  }

  func setMenuBarDisplayMode(_ mode: MenuBarDisplayMode, for provider: Provider) {
    var appearance = menuBarAppearance
    appearance.setMode(mode, for: provider)
    guard appearance != menuBarAppearance else { return }
    menuBarAppearance = appearance
    appearance.save()
  }

  func setMenuBarCustomLabel(_ label: String, for provider: Provider) {
    var appearance = menuBarAppearance
    appearance.setCustomLabel(label, for: provider)
    guard appearance != menuBarAppearance else { return }
    menuBarAppearance = appearance
    appearance.save()
  }

  func isMenuBarWindowSelected(_ windowID: String, for provider: Provider) -> Bool {
    guard let usage = states[provider]?.usage else { return false }
    return
      menuBarAppearance
      .settings(for: provider)
      .selectedWindowIDs(for: usage)
      .contains(windowID)
  }

  func setMenuBarWindowSelected(
    _ selected: Bool,
    windowID: String,
    for provider: Provider
  ) {
    var appearance = menuBarAppearance
    var settings = appearance.settings(for: provider)
    var selectedIDs = settings.selectedWindowIDs(for: states[provider]?.usage)
    if selected {
      selectedIDs.insert(windowID)
    } else {
      selectedIDs.remove(windowID)
    }
    settings.setSelectedWindowIDs(selectedIDs)
    appearance.set(settings, for: provider)
    guard appearance != menuBarAppearance else { return }
    menuBarAppearance = appearance
    appearance.save()
  }

  func menuBarWindowLabelMode(
    for windowID: String,
    provider: Provider
  ) -> MenuBarWindowLabelMode {
    menuBarAppearance.settings(for: provider).settings(for: windowID).mode
  }

  func setMenuBarWindowLabelMode(
    _ mode: MenuBarWindowLabelMode,
    for windowID: String,
    provider: Provider
  ) {
    var appearance = menuBarAppearance
    var settings = appearance.settings(for: provider)
    settings.setWindowLabelMode(mode, for: windowID)
    appearance.set(settings, for: provider)
    guard appearance != menuBarAppearance else { return }
    menuBarAppearance = appearance
    appearance.save()
  }

  func menuBarWindowCustomLabel(
    for windowID: String,
    provider: Provider
  ) -> String {
    menuBarAppearance.settings(for: provider).settings(for: windowID).customLabel
  }

  func setMenuBarWindowCustomLabel(
    _ label: String,
    for windowID: String,
    provider: Provider
  ) {
    var appearance = menuBarAppearance
    var settings = appearance.settings(for: provider)
    settings.setWindowCustomLabel(label, for: windowID)
    appearance.set(settings, for: provider)
    guard appearance != menuBarAppearance else { return }
    menuBarAppearance = appearance
    appearance.save()
  }

  var menuBarImage: NSImage {
    guard consentGranted else {
      return MenuBarLabelRenderer.image(text: "Agent Meter")
    }
    return MenuBarLabelRenderer.image(for: menuBarSegments)
  }

  var menuBarAccessibilityLabel: String {
    guard consentGranted else { return "Agent Meter" }
    return Provider.allCases
      .map { provider in menuBarAccessibility(for: provider) }
      .joined(separator: ", ")
  }

  private var menuBarSegments: [MenuBarLabelSegment] {
    Provider.allCases.flatMap { provider in menuBarSegments(for: provider) }
  }

  private func menuBarSegments(for provider: Provider) -> [MenuBarLabelSegment] {
    let settings = menuBarAppearance.settings(for: provider)
    let icon = settings.mode == .icon ? MenuBarArtwork.icon(for: provider) : nil
    let label = icon == nil ? settings.displayLabel(for: provider) : nil
    let providerSegment = MenuBarLabelSegment(icon: icon, label: label, status: "")

    guard let state = states[provider] else {
      return [MenuBarLabelSegment(icon: icon, label: label, status: "—")]
    }
    let selectedWindows = state.usage.map { settings.selectedWindows(for: $0) } ?? []
    guard !selectedWindows.isEmpty else {
      return [
        MenuBarLabelSegment(
          icon: icon,
          label: label,
          status: menuBarGroupStatus(for: state)
        )
      ]
    }
    return [providerSegment]
      + selectedWindows.map { window in
        MenuBarLabelSegment(
          icon: nil,
          label: settings.displayLabel(for: window),
          status: menuBarWindowStatus(for: state, window: window)
        )
      }
  }

  private func menuBarGroupStatus(for state: ProviderState) -> String {
    switch state.phase {
    case .loading:
      return "…"
    case .failed:
      return "!"
    case .awaitingConsent, .unavailable:
      return "—"
    case .ready:
      return "—"
    }
  }

  private func menuBarWindowStatus(for state: ProviderState, window: UsageWindow) -> String {
    switch state.phase {
    case .ready:
      return Self.percent(window.remainingPercent)
    case .loading:
      return "…"
    case .failed:
      return "!"
    case .awaitingConsent, .unavailable:
      return "—"
    }
  }

  private func menuBarAccessibility(for provider: Provider) -> String {
    let settings = menuBarAppearance.settings(for: provider)
    let providerLabel =
      settings.mode == .icon
      ? provider.displayName
      : settings.displayLabel(for: provider)
    guard let state = states[provider] else {
      return "\(providerLabel): 정보 없음"
    }
    let selectedWindows = state.usage.map { settings.selectedWindows(for: $0) } ?? []
    guard !selectedWindows.isEmpty else {
      return "\(providerLabel): \(menuBarAccessibilityGroupStatus(for: state))"
    }
    let windows = selectedWindows.map { window in
      let label = settings.displayLabel(for: window) ?? window.title
      let accessibleLabel = label.isEmpty ? window.id : label
      let status: String
      if state.phase == .ready {
        status = "\(Self.percent(window.remainingPercent)) 남음"
      } else {
        status = menuBarAccessibilityGroupStatus(for: state)
      }
      return "\(accessibleLabel): \(status)"
    }
    return "\(providerLabel): \(windows.joined(separator: ", "))"
  }

  private func menuBarAccessibilityGroupStatus(for state: ProviderState) -> String {
    switch state.phase {
    case .loading:
      return "불러오는 중"
    case .failed:
      return "오류"
    case .awaitingConsent, .unavailable, .ready:
      return "정보 없음"
    }
  }
  func acceptConsent() {
    guard !consentGranted else { return }
    consentGranted = true
    UserDefaults.standard.set(true, forKey: Self.consentKey)
    states = Dictionary(
      uniqueKeysWithValues: Provider.allCases.map {
        ($0, ProviderState(provider: $0, phase: .loading))
      })
    Task { [weak self] in
      guard let self else { return }
      await self.service.setConsent(true)
      self.restartAutomaticRefresh()
      self.refreshAll()
    }
  }

  func revokeConsent() {
    consentGranted = false
    UserDefaults.standard.set(false, forKey: Self.consentKey)
    refreshTasks.values.forEach { $0.cancel() }
    refreshTasks.removeAll()
    for provider in Provider.allCases {
      refreshGenerations[provider, default: 0] &+= 1
    }
    automaticTask?.cancel()
    automaticTask = nil
    states = Dictionary(
      uniqueKeysWithValues: Provider.allCases.map {
        ($0, ProviderState(provider: $0, phase: .awaitingConsent))
      })
    Task { [service] in
      await service.setConsent(false)
    }
  }

  func refreshAll() {
    guard consentGranted else { return }
    for provider in Provider.allCases {
      refresh(provider)
    }
  }

  func refresh(_ provider: Provider) {
    guard consentGranted, refreshTasks[provider] == nil else { return }
    refreshGenerations[provider, default: 0] &+= 1
    let generation = refreshGenerations[provider] ?? 0
    updateState(for: provider) { state in
      state.phase = .loading
      state.message = nil
      state.retryAt = nil
    }

    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.refreshGenerations[provider] == generation {
          self.refreshTasks[provider] = nil
        }
      }
      do {
        try Task.checkCancellation()
        let usage = try await self.service.fetch(provider)
        try Task.checkCancellation()
        guard self.consentGranted, self.refreshGenerations[provider] == generation else { return }
        self.updateState(for: provider) { state in
          state.usage = usage
          state.lastSuccessfulUpdate = usage.updatedAt
          state.retryAt = nil
          if usage.windows.isEmpty {
            state.phase = .unavailable
            state.message = "이 제공자는 현재 사용량 한도를 보고하지 않았습니다."
          } else {
            state.phase = .ready
            state.message = nil
          }
        }
      } catch is CancellationError {
        return
      } catch let error as UsageFetchError {
        let cachedUsage = await self.service.cachedUsage(for: provider)
        guard !Task.isCancelled,
          self.consentGranted,
          self.refreshGenerations[provider] == generation
        else { return }
        self.updateState(for: provider) { state in
          if state.usage == nil, let cachedUsage {
            state.usage = cachedUsage
            state.lastSuccessfulUpdate = cachedUsage.updatedAt
          }
          state.phase = .failed
          state.message = error.userMessage
          state.retryAt = error.retryAt
        }
      } catch {
        guard !Task.isCancelled,
          self.consentGranted,
          self.refreshGenerations[provider] == generation
        else { return }
        self.updateState(for: provider) { state in
          state.phase = .failed
          state.message = "알 수 없는 오류로 사용량을 가져오지 못했습니다."
          state.retryAt = nil
        }
      }
    }
    refreshTasks[provider] = task
  }

  private func restartAutomaticRefresh() {
    automaticTask?.cancel()
    automaticTask = nil
    guard consentGranted, let duration = refreshInterval.duration else { return }
    let nanoseconds = UInt64(duration * 1_000_000_000)
    automaticTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        self?.refreshAll()
      }
    }
  }

  private func updateState(for provider: Provider, _ update: (inout ProviderState) -> Void) {
    guard var state = states[provider] else { return }
    update(&state)
    states[provider] = state
  }

  private static func percent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
  }
}

@MainActor
private struct MenuBarLabelSegment {
  let icon: NSImage?
  let label: String?
  let status: String
}

@MainActor
private enum MenuBarArtwork {
  // Codex artwork is the image used by the official Codex product page.
  // https://chatgpt.com/codex/
  // https://images.ctfassets.net/8su2tbn87fck/37ep8OPlSuUYpcTFkkW9NO/1a6381ac6612a83ec6d07b3fac5c5228/Blossom_4k_Icon_1.png
  private static let codex = load(named: "codex")

  // Claude artwork is the official Claude web app favicon.
  // https://claude.ai/favicon.ico
  private static let claude = load(named: "claude")

  static func icon(for provider: Provider) -> NSImage? {
    switch provider {
    case .codex:
      codex
    case .claude:
      claude
    }
  }

  private static func load(named name: String) -> NSImage? {
    guard let url = AppResources.bundle?.url(forResource: name, withExtension: "png"),
      let image = NSImage(contentsOf: url)
    else {
      return nil
    }
    image.isTemplate = false
    return image
  }
}

@MainActor
private enum MenuBarLabelRenderer {
  private static let horizontalPadding: CGFloat = 2
  private static let iconDimension: CGFloat = 15
  private static let iconTextSpacing: CGFloat = 4
  private static let minimumHeight: CGFloat = 18

  static func image(text: String) -> NSImage {
    image(for: [MenuBarLabelSegment(icon: nil, label: text, status: "")])
  }

  static func image(for segments: [MenuBarLabelSegment]) -> NSImage {
    let font = NSFont.systemFont(
      ofSize: NSFont.systemFontSize(for: .small),
      weight: .regular
    )
    let statusFont = NSFont.monospacedDigitSystemFont(
      ofSize: font.pointSize,
      weight: .regular
    )
    let color = NSColor.labelColor
    let separator = attributed(" · ", font: font, color: color)
    let layouts = segments.map { segment in
      (
        segment: segment,
        label: segment.label.map { attributed($0, font: font, color: color) },
        status: segment.status.isEmpty
          ? nil
          : attributed(segment.status, font: statusFont, color: color)
      )
    }

    let textHeight = layouts.reduce(CGFloat.zero) { height, layout in
      max(height, layout.label?.size().height ?? 0, layout.status?.size().height ?? 0)
    }
    let height = max(minimumHeight, ceil(max(iconDimension, textHeight)) + 2)
    var width = horizontalPadding * 2
    for (index, layout) in layouts.enumerated() {
      if index > 0 {
        width += separator.size().width
      }
      if layout.segment.icon != nil {
        width += iconDimension
        if layout.label != nil || layout.status != nil {
          width += iconTextSpacing
        }
      }
      if let label = layout.label {
        width += label.size().width
        if layout.status != nil {
          width += iconTextSpacing
        }
      }
      if let status = layout.status {
        width += status.size().width
      }
    }

    let image = NSImage(size: NSSize(width: ceil(width), height: height))
    image.isTemplate = false
    image.lockFocusFlipped(true)
    defer { image.unlockFocus() }

    var x = horizontalPadding
    for (index, layout) in layouts.enumerated() {
      if index > 0 {
        separator.draw(at: NSPoint(x: x, y: (height - separator.size().height) / 2))
        x += separator.size().width
      }
      if let icon = layout.segment.icon {
        let y = (height - iconDimension) / 2
        icon.draw(
          in: NSRect(x: x, y: y, width: iconDimension, height: iconDimension),
          from: .zero,
          operation: .sourceOver,
          fraction: 1
        )
        x += iconDimension
        if layout.label != nil || layout.status != nil {
          x += iconTextSpacing
        }
      }
      if let label = layout.label {
        label.draw(at: NSPoint(x: x, y: (height - label.size().height) / 2))
        x += label.size().width
        if layout.status != nil {
          x += iconTextSpacing
        }
      }
      if let status = layout.status {
        status.draw(at: NSPoint(x: x, y: (height - status.size().height) / 2))
        x += status.size().width
      }
    }
    return image
  }

  private static func attributed(
    _ string: String,
    font: NSFont,
    color: NSColor
  ) -> NSAttributedString {
    NSAttributedString(
      string: string,
      attributes: [
        .font: font,
        .foregroundColor: color,
      ]
    )
  }
}
@MainActor
private struct AgentMeterMenu: View {
  @ObservedObject var model: AgentMeterModel
  let updater: SPUUpdater
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var entered = false

  var body: some View {
    VStack(spacing: 0) {
      header
      AMHairline()
      ScrollView(.vertical) {
        Group {
          if model.consentGranted {
            usageContent
          } else {
            consentContent
          }
        }
        .padding(12)
      }
      .scrollIndicators(.never)
      AMHairline()
      footer
    }
    .frame(width: 380, height: 620)
    .background(AMColor.canvas)
    .environment(\.colorScheme, .dark)
    .tint(AMColor.mute)
    .onAppear { entered = true }
    .onDisappear { entered = false }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("Agent Meter")
        .font(AMFont.inter(14, .semibold))
        .foregroundStyle(AMColor.ink)
      Spacer()
      if model.consentGranted {
        Button {
          model.refreshAll()
        } label: {
          if model.isRefreshing {
            AMSpinner(size: 11)
          } else {
            Image(systemName: "arrow.clockwise")
          }
        }
        .buttonStyle(AMIconButtonStyle())
        .disabled(model.isRefreshing)
        .help("새로 고침")
        .accessibilityLabel("새로 고침")
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 48)
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Text("모든 시간은 이 Mac의 현지 시간")
        .font(AMFont.inter(11))
        .foregroundStyle(AMColor.ash)
      Spacer()
      Button("종료") {
        NSApplication.shared.terminate(nil)
      }
      .buttonStyle(AMTertiaryButtonStyle())
    }
    .padding(.horizontal, 16)
    .frame(height: 44)
  }

  private var consentContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 12) {
        Text("사용량을 표시하려면 기존 CLI 인증 정보를 읽고 각 제공자의 usage API에 요청해야 합니다.")
          .font(AMFont.inter(13))
          .foregroundStyle(AMColor.body)
          .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 8) {
          consentSource(
            systemImage: "terminal",
            title: "Codex",
            detail: "~/.codex/auth.json (CODEX_HOME 지원)")
          consentSource(
            systemImage: "key.fill",
            title: "Claude",
            detail: "Claude Code-credentials Keychain 또는 ~/.claude/.credentials.json")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AMColor.surfaceElevated, in: RoundedRectangle(cornerRadius: AMRadius.md))
        Text(
          "토큰은 저장하거나 화면에 표시하지 않습니다. API는 공식 SDK가 아닌 비공식 usage 엔드포인트이며, 형식이나 접근 권한이 바뀌면 값을 표시하지 않습니다."
        )
        .font(AMFont.inter(11))
        .foregroundStyle(AMColor.mute)
        .fixedSize(horizontal: false, vertical: true)
        Button("허용하고 시작") {
          model.acceptConsent()
        }
        .buttonStyle(AMPrimaryButtonStyle())
      }
      .amCard()
      .amEntrance(index: 0, isVisible: entered, reduceMotion: reduceMotion)

      AMDisclosure(title: "업데이트", systemImage: "arrow.down.circle") {
        updateSettings
      }
      .amCard()
      .amEntrance(index: 1, isVisible: entered, reduceMotion: reduceMotion)
    }
  }

  private func consentSource(systemImage: String, title: String, detail: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 11))
        .foregroundStyle(AMColor.mute)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(AMFont.inter(12, .medium))
          .foregroundStyle(AMColor.ink)
        Text(detail)
          .font(AMFont.inter(11))
          .foregroundStyle(AMColor.mute)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var usageContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(Provider.allCases.enumerated()), id: \.element) { index, provider in
        if let state = model.states[provider] {
          ProviderCard(state: state)
            .amEntrance(index: index, isVisible: entered, reduceMotion: reduceMotion)
        }
      }
      AMDisclosure(title: "설정", systemImage: "gearshape") {
        settingsContent
      }
      .amCard()
      .amEntrance(
        index: Provider.allCases.count, isVisible: entered, reduceMotion: reduceMotion)
    }
  }

  private var settingsContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      AMSettingRow(title: "자동 새로 고침") {
        Picker(
          "자동 새로 고침",
          selection: Binding(
            get: { model.refreshInterval },
            set: { model.setRefreshInterval($0) }
          )
        ) {
          ForEach(RefreshInterval.allCases) { interval in
            Text(interval.label).tag(interval)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
      }
      AMHairline()
      updateSettings
      AMHairline()
      AMDisclosure(title: "상단바 표시") {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(Provider.allCases) { provider in
            MenuBarProviderSettingsRow(provider: provider, model: model)
          }
          Text("이름은 최대 20자이며 공백과 제어 문자는 정리됩니다.")
            .font(AMFont.inter(11))
            .foregroundStyle(AMColor.ash)
        }
      }
      AMHairline()
      Text(
        "Codex: chatgpt.com/backend-api/wham/usage · Claude: api.anthropic.com/api/oauth/usage (비공식 API)"
      )
      .font(AMFont.inter(11))
      .foregroundStyle(AMColor.ash)
      .fixedSize(horizontal: false, vertical: true)
      Button("인증 정보 읽기 동의 철회") {
        model.revokeConsent()
      }
      .buttonStyle(.plain)
      .font(AMFont.inter(11, .medium))
      .foregroundStyle(AMColor.mute)
    }
  }

  private var updateSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      UpdaterSettingsView(updater: updater)
      Button("업데이트 확인…") {
        updater.checkForUpdates()
      }
      .buttonStyle(AMTertiaryButtonStyle())
    }
  }
}

@MainActor
private struct UpdaterSettingsView: View {
  let updater: SPUUpdater
  @State private var automaticallyChecksForUpdates: Bool
  @State private var automaticallyDownloadsUpdates: Bool

  init(updater: SPUUpdater) {
    self.updater = updater
    _automaticallyChecksForUpdates = State(
      initialValue: updater.automaticallyChecksForUpdates
    )
    _automaticallyDownloadsUpdates = State(
      initialValue: updater.automaticallyDownloadsUpdates
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      AMSettingRow(title: "업데이트 자동 확인") {
        Toggle("업데이트 자동 확인", isOn: $automaticallyChecksForUpdates)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.mini)
          .onChange(of: automaticallyChecksForUpdates) { _, enabled in
            updater.automaticallyChecksForUpdates = enabled
          }
      }
      AMSettingRow(title: "업데이트 자동 다운로드 및 설치") {
        Toggle("업데이트 자동 다운로드 및 설치", isOn: $automaticallyDownloadsUpdates)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.mini)
          .disabled(!automaticallyChecksForUpdates)
          .onChange(of: automaticallyDownloadsUpdates) { _, enabled in
            updater.automaticallyDownloadsUpdates = enabled
          }
      }
    }
  }
}

@MainActor
private struct ProviderCard: View {
  let state: ProviderState

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        providerIcon
        Text(state.provider.displayName)
          .font(AMFont.inter(14, .medium))
          .foregroundStyle(AMColor.ink)
        Spacer()
        AMStatusPill(phase: state.phase)
      }
      if let usage = state.usage, !usage.windows.isEmpty {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(usage.windows) { window in
            UsageWindowRow(window: window)
          }
        }
      } else if state.phase == .loading {
        placeholder("사용량을 확인하는 중…")
      } else if state.phase == .unavailable {
        placeholder("사용량 한도 정보 없음")
      }
      if let credits = state.usage?.credits {
        VStack(spacing: 10) {
          AMHairline()
          HStack(alignment: .firstTextBaseline) {
            Text("크레딧 잔량")
              .font(AMFont.inter(13))
              .foregroundStyle(AMColor.body)
            Spacer()
            Text(Self.creditText(credits))
              .font(AMFont.inter(13, .semibold))
              .monospacedDigit()
              .foregroundStyle(AMColor.ink)
          }
        }
      }
      if let message = state.message {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(state.phase == .failed ? AMColor.accentRed : AMColor.mute)
          Text(message)
            .font(AMFont.inter(11))
            .foregroundStyle(AMColor.body)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AMColor.surfaceElevated, in: RoundedRectangle(cornerRadius: AMRadius.sm))
      }
      if state.lastSuccessfulUpdate != nil || state.retryAt != nil {
        HStack(spacing: 10) {
          if let lastSuccessfulUpdate = state.lastSuccessfulUpdate {
            Text("마지막 성공 \(Self.localDate(lastSuccessfulUpdate))")
          }
          if let retryAt = state.retryAt {
            Text("다음 시도 \(Self.localDate(retryAt))")
          }
        }
        .font(AMFont.inter(11))
        .foregroundStyle(AMColor.ash)
      }
    }
    .amCard()
  }

  @ViewBuilder
  private var providerIcon: some View {
    if let icon = MenuBarArtwork.icon(for: state.provider) {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: 16, height: 16)
        .padding(3)
        .background(AMColor.surfaceCard, in: RoundedRectangle(cornerRadius: AMRadius.sm))
        .overlay(
          RoundedRectangle(cornerRadius: AMRadius.sm)
            .strokeBorder(AMColor.hairline, lineWidth: 1))
        .accessibilityHidden(true)
    }
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(AMFont.inter(12))
      .foregroundStyle(AMColor.mute)
  }

  private static func creditText(_ credits: CreditBalance) -> String {
    if credits.isUnlimited { return "무제한" }
    if let currencyCode = credits.currencyCode {
      return credits.remaining.formatted(.currency(code: currencyCode).presentation(.narrow))
    }
    return "\(credits.remaining.formatted(.number.precision(.fractionLength(0...2)))) 크레딧"
  }

  fileprivate static func localDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }
}

@MainActor
private struct UsageWindowRow: View {
  let window: UsageWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(window.title)
          .font(AMFont.inter(13))
          .foregroundStyle(AMColor.body)
        Spacer()
        AMCountingPercent(value: window.remainingPercent)
        Text("남음")
          .font(AMFont.inter(11))
          .foregroundStyle(AMColor.mute)
      }
      AMMeterBar(value: window.remainingPercent, level: window.level)
      Text(
        window.resetAt.map { "초기화 \(ProviderCard.localDate($0))" } ?? "초기화 시간 정보 없음"
      )
      .font(AMFont.inter(11))
      .foregroundStyle(AMColor.ash)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(window.title)
    .accessibilityValue("\(Int(window.remainingPercent.rounded()))% 남음")
  }
}

@MainActor
private struct MenuBarProviderSettingsRow: View {
  let provider: Provider
  @ObservedObject var model: AgentMeterModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(provider.displayName)
          .font(AMFont.inter(12, .semibold))
          .foregroundStyle(AMColor.ink)
        Spacer()
        Picker(
          "표시 방식",
          selection: Binding(
            get: { model.menuBarAppearance.settings(for: provider).mode },
            set: { model.setMenuBarDisplayMode($0, for: provider) }
          )
        ) {
          Text("텍스트").tag(MenuBarDisplayMode.text)
          Text("아이콘").tag(MenuBarDisplayMode.icon)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 124)
      }
      let settings = model.menuBarAppearance.settings(for: provider)
      if settings.mode == .text {
        TextField(
          "\(provider.displayName) 표시 이름 (기본값: \(provider.displayName))",
          text: Binding(
            get: { model.menuBarAppearance.settings(for: provider).customLabel },
            set: { model.setMenuBarCustomLabel($0, for: provider) }
          )
        )
        .textFieldStyle(AMTextFieldStyle())
      } else {
        Text("제공자 공식 아이콘")
          .font(AMFont.inter(11))
          .foregroundStyle(AMColor.ash)
      }
      Text("표시할 사용량")
        .font(AMFont.inter(11, .medium))
        .foregroundStyle(AMColor.mute)
        .padding(.top, 2)
      if let usage = model.states[provider]?.usage, !usage.windows.isEmpty {
        ForEach(usage.windows) { window in
          MenuBarWindowSettingsRow(
            provider: provider,
            window: window,
            model: model
          )
        }
      } else {
        Text("사용량 한도 목록을 불러오면 선택할 수 있습니다.")
          .font(AMFont.inter(11))
          .foregroundStyle(AMColor.ash)
      }
    }
    .padding(10)
    .background(AMColor.surfaceElevated, in: RoundedRectangle(cornerRadius: AMRadius.md))
  }

}

@MainActor
private struct MenuBarWindowSettingsRow: View {
  let provider: Provider
  let window: UsageWindow
  @ObservedObject var model: AgentMeterModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Toggle(
          isOn: Binding(
            get: { model.isMenuBarWindowSelected(window.id, for: provider) },
            set: {
              model.setMenuBarWindowSelected(
                $0,
                windowID: window.id,
                for: provider
              )
            }
          )
        ) {
          Text(window.title)
            .font(AMFont.inter(12))
            .foregroundStyle(AMColor.body)
            .lineLimit(1)
        }
        .toggleStyle(.checkbox)
        Spacer(minLength: 4)
        Picker(
          "라벨",
          selection: Binding(
            get: { model.menuBarWindowLabelMode(for: window.id, provider: provider) },
            set: {
              model.setMenuBarWindowLabelMode(
                $0,
                for: window.id,
                provider: provider
              )
            }
          )
        ) {
          ForEach(MenuBarWindowLabelMode.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
      }
      if model.menuBarWindowLabelMode(for: window.id, provider: provider) == .custom {
        TextField(
          "직접 입력 (비워두면 라벨 숨김)",
          text: Binding(
            get: { model.menuBarWindowCustomLabel(for: window.id, provider: provider) },
            set: {
              model.setMenuBarWindowCustomLabel(
                $0,
                for: window.id,
                provider: provider
              )
            }
          )
        )
        .textFieldStyle(AMTextFieldStyle())
      }
    }
  }
}
