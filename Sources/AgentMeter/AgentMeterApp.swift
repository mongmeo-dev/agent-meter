import AgentMeterCore
import AppKit
import SwiftUI

@main
@MainActor
struct AgentMeterApp: App {
  @StateObject private var model = AgentMeterModel()

  var body: some Scene {
    MenuBarExtra {
      AgentMeterMenu(model: model)
    } label: {
      Image(nsImage: model.menuBarImage)
        .accessibilityLabel(Text(model.menuBarAccessibilityLabel))
    }
    .menuBarExtraStyle(.window)
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
    self.service = UsageService()
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
        guard !Task.isCancelled,
          self.consentGranted,
          self.refreshGenerations[provider] == generation
        else { return }
        self.updateState(for: provider) { state in
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
    let resources: Bundle?
    if Bundle.main.bundleURL.pathExtension == "app" {
      resources = Bundle.main.resourceURL
        .flatMap { Bundle(url: $0.appendingPathComponent("AgentMeter_AgentMeter.bundle")) }
    } else {
      resources = Bundle.module
    }
    guard let url = resources?.url(forResource: name, withExtension: "png"),
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

  var body: some View {
    ScrollView(.vertical) {
      Group {
        if model.consentGranted {
          usageContent
        } else {
          consentContent
        }
      }
      .padding(14)
      .frame(width: 390, alignment: .leading)
    }
    .frame(width: 390, height: 640)
  }

  private var consentContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Agent Meter")
        .font(.headline)
      Text("사용량을 표시하려면 기존 CLI 인증 정보를 읽고 각 제공자의 usage API에 요청해야 합니다.")
        .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 5) {
        Label("Codex: ~/.codex/auth.json (CODEX_HOME 지원)", systemImage: "terminal")
        Label(
          "Claude: Claude Code-credentials Keychain 또는 ~/.claude/.credentials.json",
          systemImage: "key.fill")
      }
      Text(
        "토큰은 저장하거나 화면에 표시하지 않습니다. API는 공식 SDK가 아닌 비공식 usage 엔드포인트이며, 형식이나 접근 권한이 바뀌면 값을 표시하지 않습니다."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("허용하고 시작") {
          model.acceptConsent()
        }
        .buttonStyle(.borderedProminent)
        Button("종료") {
          NSApplication.shared.terminate(nil)
        }
      }
    }
  }

  private var usageContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Provider.allCases) { provider in
        if let state = model.states[provider] {
          ProviderCard(state: state)
        }
      }
      Divider()
      HStack {
        Button {
          model.refreshAll()
        } label: {
          Label("새로 고침", systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)
        Spacer()
        Button("종료") {
          NSApplication.shared.terminate(nil)
        }
      }
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
      .pickerStyle(.menu)
      menuBarAppearanceSettings
      Text("모든 시간은 이 Mac의 현지 시간")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(
        "Codex: chatgpt.com/backend-api/wham/usage · Claude: api.anthropic.com/api/oauth/usage (비공식 API)"
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Button("인증 정보 읽기 동의 철회") {
        model.revokeConsent()
      }
      .font(.caption)
      .buttonStyle(.link)
    }
  }

  private var menuBarAppearanceSettings: some View {
    DisclosureGroup("상단바 표시 설정") {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Provider.allCases) { provider in
          MenuBarProviderSettingsRow(provider: provider, model: model)
        }
        Text("이름은 최대 20자이며 공백과 제어 문자는 정리됩니다.")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 4)
    }
  }
}

@MainActor
private struct ProviderCard: View {
  let state: ProviderState

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(state.provider.displayName)
          .font(.headline)
        Spacer()
        phaseView
      }
      if let usage = state.usage, !usage.windows.isEmpty {
        ForEach(usage.windows) { window in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(window.title)
              Spacer()
              Text(Self.percent(window.remainingPercent))
                .monospacedDigit()
                .fontWeight(.semibold)
            }
            ProgressView(value: window.remainingPercent, total: 100)
            if let resetAt = window.resetAt {
              Text("초기화: \(Self.localDate(resetAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
              Text("초기화 시간 정보 없음")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      } else if state.phase == .loading {
        Text("사용량을 확인하는 중…")
          .foregroundStyle(.secondary)
      } else if state.phase == .unavailable {
        Text("사용량 한도 정보 없음")
          .foregroundStyle(.secondary)
      }
      if let message = state.message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let lastSuccessfulUpdate = state.lastSuccessfulUpdate {
        Text("마지막 성공: \(Self.localDate(lastSuccessfulUpdate))")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      if let retryAt = state.retryAt {
        Text("다음 시도 가능: \(Self.localDate(retryAt))")
          .font(.caption2)
          .foregroundStyle(.orange)
      }
    }
    .padding(10)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
  }

  @ViewBuilder
  private var phaseView: some View {
    switch state.phase {
    case .loading:
      ProgressView()
        .controlSize(.small)
    case .ready:
      Text("정상")
        .font(.caption)
        .foregroundStyle(.green)
    case .unavailable:
      Text("정보 없음")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .failed:
      Text("오류")
        .font(.caption)
        .foregroundStyle(.red)
    case .awaitingConsent:
      Text("동의 필요")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private static func percent(_ value: Double) -> String {
    "\(Int(value.rounded()))% 남음"
  }

  private static func localDate(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }
}

@MainActor
private struct MenuBarProviderSettingsRow: View {
  let provider: Provider
  @ObservedObject var model: AgentMeterModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(provider.displayName)
          .font(.subheadline)
          .fontWeight(.semibold)
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
        .textFieldStyle(.roundedBorder)
      } else {
        Text("제공자 공식 아이콘")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Divider()
      Text("표시할 사용량")
        .font(.caption)
        .foregroundStyle(.secondary)
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
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }

}

@MainActor
private struct MenuBarWindowSettingsRow: View {
  let provider: Provider
  let window: UsageWindow
  @ObservedObject var model: AgentMeterModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
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
            .lineLimit(1)
        }
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
        .textFieldStyle(.roundedBorder)
      }
    }
  }
}
