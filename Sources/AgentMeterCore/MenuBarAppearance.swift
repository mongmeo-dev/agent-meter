import Foundation

public enum MenuBarDisplayMode: String, CaseIterable, Codable, Hashable, Sendable {
  case text
  case icon

  public var label: String {
    switch self {
    case .text:
      "텍스트"
    case .icon:
      "아이콘"
    }
  }
}

public enum MenuBarWindowLabelMode: String, CaseIterable, Codable, Hashable, Sendable {
  case hidden
  case title
  case custom

  public var label: String {
    switch self {
    case .hidden:
      "숨김"
    case .title:
      "한도명"
    case .custom:
      "직접 입력"
    }
  }
}

public struct MenuBarWindowSettings: Codable, Equatable, Sendable {
  public var mode: MenuBarWindowLabelMode
  public var customLabel: String {
    didSet {
      customLabel = MenuBarProviderSettings.normalizeLabel(customLabel)
    }
  }

  public init(mode: MenuBarWindowLabelMode = .title, customLabel: String = "") {
    self.mode = mode
    self.customLabel = MenuBarProviderSettings.normalizeLabel(customLabel)
  }

  public func displayLabel(for window: UsageWindow) -> String? {
    switch mode {
    case .hidden:
      return nil
    case .title:
      return window.title
    case .custom:
      let label = MenuBarProviderSettings.normalizeLabel(customLabel)
      return label.isEmpty ? nil : label
    }
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case customLabel
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawMode =
      (try? container.decode(String.self, forKey: .mode)) ?? MenuBarWindowLabelMode.title.rawValue
    mode = MenuBarWindowLabelMode(rawValue: rawMode) ?? .title
    let rawLabel = (try? container.decode(String.self, forKey: .customLabel)) ?? ""
    customLabel = MenuBarProviderSettings.normalizeLabel(rawLabel)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode.rawValue, forKey: .mode)
    try container.encode(MenuBarProviderSettings.normalizeLabel(customLabel), forKey: .customLabel)
  }
}

public struct MenuBarProviderSettings: Codable, Equatable, Sendable {
  public static let maxLabelLength = 20

  public var mode: MenuBarDisplayMode
  public var customLabel: String {
    didSet {
      customLabel = Self.normalizeLabel(customLabel)
    }
  }
  /// `nil` means the initial default (the first usage window). An empty set is
  /// an explicit choice to show no usage windows.
  public var selectedWindowIDs: Set<String>?
  public var windowSettings: [String: MenuBarWindowSettings]

  public init(
    mode: MenuBarDisplayMode = .text,
    customLabel: String = "",
    selectedWindowIDs: Set<String>? = nil,
    windowSettings: [String: MenuBarWindowSettings] = [:]
  ) {
    self.mode = mode
    self.customLabel = Self.normalizeLabel(customLabel)
    self.selectedWindowIDs = selectedWindowIDs
    self.windowSettings = windowSettings
  }

  public var usesIcon: Bool {
    mode == .icon
  }

  public func displayLabel(for provider: Provider) -> String {
    let label = Self.normalizeLabel(customLabel)
    return label.isEmpty ? provider.displayName : label
  }

  public func selectedWindowIDs(for usage: ProviderUsage?) -> Set<String> {
    guard let selectedWindowIDs else {
      guard let firstID = usage?.windows.first?.id else { return [] }
      return [firstID]
    }
    return selectedWindowIDs
  }

  public func selectedWindows(for usage: ProviderUsage) -> [UsageWindow] {
    let selectedIDs = selectedWindowIDs(for: usage)
    return usage.windows.filter { selectedIDs.contains($0.id) }
  }

  public func settings(for windowID: String) -> MenuBarWindowSettings {
    windowSettings[windowID] ?? MenuBarWindowSettings()
  }

  public func displayLabel(for window: UsageWindow) -> String? {
    settings(for: window.id).displayLabel(for: window)
  }

  public mutating func setSelectedWindowIDs(_ ids: Set<String>?) {
    selectedWindowIDs = ids
  }

  public mutating func setWindowLabelMode(
    _ mode: MenuBarWindowLabelMode,
    for windowID: String
  ) {
    var settings = self.settings(for: windowID)
    settings.mode = mode
    windowSettings[windowID] = settings
  }

  public mutating func setWindowCustomLabel(_ label: String, for windowID: String) {
    var settings = self.settings(for: windowID)
    settings.customLabel = label
    windowSettings[windowID] = settings
  }

  public static func normalizeLabel(_ value: String) -> String {
    let sanitized = value.unicodeScalars.map { scalar -> String in
      if CharacterSet.controlCharacters.contains(scalar)
        || CharacterSet.newlines.contains(scalar)
      {
        return " "
      }
      return String(scalar)
    }.joined()
    let collapsed = sanitized.split { character in character.isWhitespace }.joined(separator: " ")
    return String(collapsed.prefix(Self.maxLabelLength))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private enum CodingKeys: String, CodingKey {
    case mode
    case customLabel
    case selectedWindowIDs
    case windowSettings
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawMode =
      (try? container.decode(String.self, forKey: .mode)) ?? MenuBarDisplayMode.text.rawValue
    mode = MenuBarDisplayMode(rawValue: rawMode) ?? .text
    let rawLabel = (try? container.decode(String.self, forKey: .customLabel)) ?? ""
    customLabel = Self.normalizeLabel(rawLabel)
    if container.contains(.selectedWindowIDs) {
      selectedWindowIDs =
        (try? container.decode(Set<String>.self, forKey: .selectedWindowIDs)) ?? []
    } else {
      selectedWindowIDs = nil
    }
    windowSettings =
      (try? container.decode([String: MenuBarWindowSettings].self, forKey: .windowSettings)) ?? [:]
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode.rawValue, forKey: .mode)
    try container.encode(Self.normalizeLabel(customLabel), forKey: .customLabel)
    try container.encodeIfPresent(selectedWindowIDs, forKey: .selectedWindowIDs)
    try container.encode(windowSettings, forKey: .windowSettings)
  }
}

public struct MenuBarAppearance: Codable, Equatable, Sendable {
  public static let userDefaultsKey = "AgentMeter.menuBarAppearance"
  public static let defaultValue = MenuBarAppearance()

  public var codex: MenuBarProviderSettings
  public var claude: MenuBarProviderSettings

  public init(
    codex: MenuBarProviderSettings = MenuBarProviderSettings(),
    claude: MenuBarProviderSettings = MenuBarProviderSettings()
  ) {
    self.codex = codex
    self.claude = claude
  }

  public func settings(for provider: Provider) -> MenuBarProviderSettings {
    switch provider {
    case .codex:
      codex
    case .claude:
      claude
    }
  }

  public subscript(provider: Provider) -> MenuBarProviderSettings {
    get { settings(for: provider) }
    set {
      switch provider {
      case .codex:
        codex = newValue
      case .claude:
        claude = newValue
      }
    }
  }

  public mutating func set(_ settings: MenuBarProviderSettings, for provider: Provider) {
    self[provider] = settings
  }

  public mutating func setMode(_ mode: MenuBarDisplayMode, for provider: Provider) {
    var settings = self[provider]
    settings.mode = mode
    self[provider] = settings
  }

  public mutating func setCustomLabel(_ label: String, for provider: Provider) {
    var settings = self[provider]
    settings.customLabel = label
    self[provider] = settings
  }

  public static func load(from defaults: UserDefaults = .standard) -> MenuBarAppearance {
    guard let data = defaults.data(forKey: userDefaultsKey),
      let appearance = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return defaultValue
    }
    return appearance
  }

  public func save(to defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.userDefaultsKey)
  }

  private enum CodingKeys: String, CodingKey {
    case codex
    case claude
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    codex =
      (try? container.decode(MenuBarProviderSettings.self, forKey: .codex))
      ?? MenuBarProviderSettings()
    claude =
      (try? container.decode(MenuBarProviderSettings.self, forKey: .claude))
      ?? MenuBarProviderSettings()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(codex, forKey: .codex)
    try container.encode(claude, forKey: .claude)
  }
}
