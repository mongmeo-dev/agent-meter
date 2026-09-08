import Foundation

public enum RefreshInterval: Int, CaseIterable, Hashable, Identifiable, Sendable {
  case off = 0
  case oneMinute = 60
  case fiveMinutes = 300
  case tenMinutes = 600
  case fifteenMinutes = 900
  case thirtyMinutes = 1_800

  public static let defaultValue: RefreshInterval = .fiveMinutes
  public static let userDefaultsKey = "AgentMeter.refreshInterval"

  public var id: Int { rawValue }

  public var label: String {
    switch self {
    case .off:
      "끔"
    case .oneMinute:
      "1분"
    case .fiveMinutes:
      "5분"
    case .tenMinutes:
      "10분"
    case .fifteenMinutes:
      "15분"
    case .thirtyMinutes:
      "30분"
    }
  }

  public var duration: TimeInterval? {
    guard self != .off else { return nil }
    return TimeInterval(rawValue)
  }

  public static func load(from defaults: UserDefaults = .standard) -> RefreshInterval {
    guard let rawValue = defaults.object(forKey: userDefaultsKey) as? Int,
      let interval = RefreshInterval(rawValue: rawValue)
    else {
      return defaultValue
    }
    return interval
  }

  public func save(to defaults: UserDefaults = .standard) {
    defaults.set(rawValue, forKey: Self.userDefaultsKey)
  }
}
