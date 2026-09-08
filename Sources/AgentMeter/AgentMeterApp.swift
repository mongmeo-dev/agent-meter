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
      Text(model.menuBarLabel)
        .monospacedDigit()
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
  @Published private(set) var states: [Provider: ProviderState]

  init() {
    self.service = UsageService()
    let granted = UserDefaults.standard.bool(forKey: Self.consentKey)
    self.consentGranted = granted
    self.states = Dictionary(
      uniqueKeysWithValues: Provider.allCases.map {
        ($0, ProviderState(provider: $0, phase: granted ? .loading : .awaitingConsent))
      })

    if granted {
      Task { [weak self] in
        guard let self else { return }
        await self.service.setConsent(true)
        self.startAutomaticRefresh()
        self.refreshAll()
      }
    }
  }

  var isRefreshing: Bool { !refreshTasks.isEmpty }

  var menuBarLabel: String {
    guard consentGranted else { return "Agent Meter" }
    return Provider.allCases.map { summary(for: $0) }.joined(separator: " · ")
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
      self.startAutomaticRefresh()
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

  private func startAutomaticRefresh() {
    automaticTask?.cancel()
    automaticTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 300_000_000_000)
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

  private func summary(for provider: Provider) -> String {
    let shortName = provider == .codex ? "Codex" : "Claude"
    guard let state = states[provider] else { return "\(shortName) —" }
    switch state.phase {
    case .loading:
      return "\(shortName) …"
    case .failed:
      return "\(shortName) !"
    case .awaitingConsent, .unavailable:
      return "\(shortName) —"
    case .ready:
      break
    }
    if let window = state.usage?.windows.first {
      return "\(shortName) \(Self.percent(window.remainingPercent))"
    }
    return "\(shortName) —"
  }

  private static func percent(_ value: Double) -> String {
    "\(Int(value.rounded()))%"
  }
}

@MainActor
private struct AgentMeterMenu: View {
  @ObservedObject var model: AgentMeterModel

  var body: some View {
    Group {
      if model.consentGranted {
        usageContent
      } else {
        consentContent
      }
    }
    .padding(14)
    .frame(width: 390)
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
      Text("자동 새로 고침: 5분마다 · 모든 시간은 이 Mac의 현지 시간")
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
