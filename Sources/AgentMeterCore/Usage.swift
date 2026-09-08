import Foundation

#if canImport(Security)
  import Security
#endif

public enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
  case codex
  case claude

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    }
  }
}

public struct UsageWindow: Identifiable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let remainingPercent: Double
  public let resetAt: Date?

  public init(id: String, title: String, remainingPercent: Double, resetAt: Date?) {
    self.id = id
    self.title = title
    self.remainingPercent = min(100, max(0, remainingPercent))
    self.resetAt = resetAt
  }

}

public struct ProviderUsage: Equatable, Sendable {
  public let provider: Provider
  public let windows: [UsageWindow]
  public let updatedAt: Date

  public init(provider: Provider, windows: [UsageWindow], updatedAt: Date = Date()) {
    self.provider = provider
    self.windows = windows
    self.updatedAt = updatedAt
  }
}

public enum ProviderPhase: String, Equatable, Sendable {
  case awaitingConsent
  case loading
  case ready
  case unavailable
  case failed
}

public struct ProviderState: Equatable, Sendable {
  public let provider: Provider
  public var phase: ProviderPhase
  public var usage: ProviderUsage?
  public var message: String?
  public var lastSuccessfulUpdate: Date?
  public var retryAt: Date?

  public init(
    provider: Provider,
    phase: ProviderPhase = .awaitingConsent,
    usage: ProviderUsage? = nil,
    message: String? = nil,
    lastSuccessfulUpdate: Date? = nil,
    retryAt: Date? = nil
  ) {
    self.provider = provider
    self.phase = phase
    self.usage = usage
    self.message = message
    self.lastSuccessfulUpdate = lastSuccessfulUpdate
    self.retryAt = retryAt
  }
}

public struct CodexCredentials: Sendable {
  public let accessToken: String
  public let accountID: String?

  public init(accessToken: String, accountID: String? = nil) {
    self.accessToken = accessToken
    self.accountID = accountID
  }

  public var isAccountScoped: Bool { accountID?.isEmpty == false }
}

public struct ClaudeCredentials: Sendable {
  public let accessToken: String
  public let expiresAt: Date?

  public init(accessToken: String, expiresAt: Date? = nil) {
    self.accessToken = accessToken
    self.expiresAt = expiresAt
  }
}

public enum CredentialError: Error, LocalizedError, Equatable, Sendable {
  case missing(Provider)
  case invalid(Provider)
  case expired(Provider)
  case keychainUnavailable

  public var errorDescription: String? {
    switch self {
    case .missing(.codex):
      "Codex 인증 정보를 찾을 수 없습니다. 터미널에서 `codex login`을 실행한 뒤 새로 고침하세요."
    case .missing(.claude):
      "Claude 인증 정보를 찾을 수 없습니다. 터미널에서 `claude`를 실행해 로그인한 뒤 새로 고침하세요."
    case .invalid(.codex):
      "Codex 인증 파일 형식을 읽을 수 없습니다. `codex login`을 다시 실행한 뒤 새로 고침하세요."
    case .invalid(.claude):
      "Claude 인증 정보 형식을 읽을 수 없습니다. `claude logout && claude login` 후 새로 고침하세요."
    case .expired(.codex):
      "Codex 인증이 만료되었습니다. 터미널에서 `codex login`을 실행한 뒤 새로 고침하세요."
    case .expired(.claude):
      "Claude 인증이 만료되었습니다. 터미널에서 `claude logout && claude login` 후 새로 고침하세요."
    case .keychainUnavailable:
      "Claude Code Keychain 항목에 접근할 수 없습니다. 터미널에서 `claude`를 실행해 로그인하고 Keychain 접근을 허용하세요."
    }
  }
}

public enum UsageParsingError: Error, LocalizedError, Equatable, Sendable {
  case invalidSchema(Provider)

  public var errorDescription: String? {
    switch self {
    case .invalidSchema(let provider):
      "\(provider.displayName) usage API 응답 형식이 바뀌었거나 올바르지 않습니다."
    }
  }
}

public enum UsageTransportError: Error, LocalizedError, Equatable, Sendable {
  case connectionFailed
  case invalidResponse
  case redirectDenied

  public var errorDescription: String? {
    switch self {
    case .connectionFailed:
      "네트워크에 연결할 수 없습니다."
    case .invalidResponse:
      "네트워크 응답을 확인할 수 없습니다."
    case .redirectDenied:
      "보안상 허용되지 않은 리디렉션입니다."
    }
  }
}

public enum UsageFetchError: Error, LocalizedError, Equatable, Sendable {
  case consentRequired
  case missingCredentials(Provider)
  case invalidCredentials(Provider)
  case expiredCredentials(Provider)
  case keychainUnavailable
  case unauthorized(Provider)
  case forbidden(Provider)
  case rateLimited(Provider, retryAt: Date?)
  case serverError(Provider, statusCode: Int)
  case invalidResponse(Provider)
  case network(Provider)

  public var retryAt: Date? {
    guard case .rateLimited(_, let date) = self else { return nil }
    return date
  }

  public var userMessage: String {
    switch self {
    case .consentRequired:
      "먼저 인증 정보 및 네트워크 접근을 허용해야 합니다."
    case .missingCredentials(let provider):
      CredentialError.missing(provider).localizedDescription
    case .invalidCredentials(let provider):
      CredentialError.invalid(provider).localizedDescription
    case .expiredCredentials(let provider):
      CredentialError.expired(provider).localizedDescription
    case .keychainUnavailable:
      CredentialError.keychainUnavailable.localizedDescription
    case .unauthorized(.codex):
      "Codex 사용량 API 인증이 거부되었습니다. `codex login` 후 새로 고침하세요."
    case .unauthorized(.claude):
      "Claude 사용량 API 인증이 거부되었습니다. `claude logout && claude login` 후 새로 고침하세요."
    case .forbidden(let provider):
      "\(provider.displayName) 사용량 API 접근 권한이 없습니다. CLI 로그인 상태와 계정 권한을 확인하세요."
    case .rateLimited(let provider, let retryAt):
      if retryAt == nil {
        "\(provider.displayName) API 요청이 제한되었습니다. 잠시 후 다시 시도하세요."
      } else {
        "\(provider.displayName) API 요청이 제한되었습니다. 지정된 대기 시간이 지나면 다시 시도하세요."
      }
    case .serverError(let provider, let statusCode):
      "\(provider.displayName) 서버 오류(HTTP \(statusCode))입니다. 잠시 후 다시 시도하세요."
    case .invalidResponse(let provider):
      "\(provider.displayName) 사용량 응답을 해석할 수 없습니다. 제공자 API 형식이 바뀌었을 수 있습니다."
    case .network(let provider):
      "\(provider.displayName) 네트워크 요청에 실패했습니다. 연결 상태를 확인하세요."
    }
  }

  public var errorDescription: String? { userMessage }
}

public protocol CredentialReader: Sendable {
  func readCodexCredentials() throws -> CodexCredentials
  func readClaudeCredentials() throws -> ClaudeCredentials
}

private enum CredentialJSONError: Error {
  case malformed
}

private enum KeychainReadError: Error {
  case notFound
  case unavailable
  case malformed
}

private enum JSONSupport {
  static func object(from data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CredentialJSONError.malformed
    }
    return object
  }

  static func string(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func number(_ value: Any?) -> Double? {
    guard let value else { return nil }
    guard let number = value as? NSNumber else { return nil }
    if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return nil }
    let result = number.doubleValue
    return result.isFinite ? result : nil
  }

  static func dateValue(_ value: Any?) -> Date? {
    if let number = number(value) {
      guard number.isFinite else { return nil }
      let seconds = abs(number) > 100_000_000_000 ? number / 1_000 : number
      return Date(timeIntervalSince1970: seconds)
    }
    if let string = string(value) {
      if let number = Double(string) {
        let seconds = abs(number) > 100_000_000_000 ? number / 1_000 : number
        return Date(timeIntervalSince1970: seconds)
      }
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = formatter.date(from: string) { return date }
      formatter.formatOptions = [.withInternetDateTime]
      return formatter.date(from: string)
    }
    return nil
  }
}

public struct LocalCredentialReader: CredentialReader, Sendable {
  private let environment: [String: String]
  private let homeDirectory: URL

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.environment = environment
    self.homeDirectory = homeDirectory
  }

  public func readCodexCredentials() throws -> CodexCredentials {
    let root = codexHomeURL()
    let url = root.appendingPathComponent("auth.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CredentialError.missing(.codex)
    }
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      let object = try? JSONSupport.object(from: data),
      let tokens = object["tokens"] as? [String: Any],
      let accessToken = JSONSupport.string(tokens["access_token"])
    else {
      throw CredentialError.invalid(.codex)
    }

    if let expiry = Self.jwtExpiry(accessToken), expiry <= Date() {
      throw CredentialError.expired(.codex)
    }
    let accountID = JSONSupport.string(tokens["account_id"])
    return CodexCredentials(accessToken: accessToken, accountID: accountID)
  }

  public func readClaudeCredentials() throws -> ClaudeCredentials {
    var keychainUnavailable = false
    #if canImport(Security)
      do {
        let data = try Self.readClaudeKeychainData()
        if let credentials = try? Self.parseClaudeCredentials(data: data) {
          return try Self.validated(credentials)
        }
      } catch let error as CredentialError {
        throw error
      } catch KeychainReadError.notFound {
        // The CLI also supports the file below, so continue to it.
      } catch {
        keychainUnavailable = true
      }
    #endif

    let url =
      homeDirectory
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent(".credentials.json", isDirectory: false)
    guard FileManager.default.fileExists(atPath: url.path) else {
      if keychainUnavailable { throw CredentialError.keychainUnavailable }
      throw CredentialError.missing(.claude)
    }
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
      throw CredentialError.invalid(.claude)
    }
    guard let credentials = try? Self.parseClaudeCredentials(data: data) else {
      throw CredentialError.invalid(.claude)
    }
    return try Self.validated(credentials)
  }

  private func codexHomeURL() -> URL {
    guard
      let configured = environment["CODEX_HOME"]?
        .trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty
    else {
      return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }
    if configured == "~" { return homeDirectory }
    if configured.hasPrefix("~/") {
      return homeDirectory.appendingPathComponent(String(configured.dropFirst(2)))
    }
    if configured.hasPrefix("/") {
      return URL(fileURLWithPath: configured, isDirectory: true)
    }
    return homeDirectory.appendingPathComponent(configured, isDirectory: true)
  }

  private static func parseClaudeCredentials(data: Data) throws -> ClaudeCredentials {
    guard let object = try? JSONSupport.object(from: data),
      let oauth = object["claudeAiOauth"] as? [String: Any],
      let accessToken = JSONSupport.string(oauth["accessToken"])
    else {
      throw CredentialJSONError.malformed
    }
    return ClaudeCredentials(
      accessToken: accessToken,
      expiresAt: JSONSupport.dateValue(oauth["expiresAt"]))
  }

  private static func validated(_ credentials: ClaudeCredentials) throws -> ClaudeCredentials {
    if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
      throw CredentialError.expired(.claude)
    }
    return credentials
  }

  private static func jwtExpiry(_ token: String) -> Date? {
    let segments = token.split(separator: ".")
    guard segments.count >= 2 else { return nil }
    var encoded = String(segments[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded.append("=") }
    guard let data = Data(base64Encoded: encoded),
      let object = try? JSONSerialization.jsonObject(with: data),
      let claims = object as? [String: Any]
    else { return nil }
    return JSONSupport.dateValue(claims["exp"])
  }

  #if canImport(Security)
    private static func readClaudeKeychainData() throws -> Data {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      switch status {
      case errSecSuccess:
        guard let data = result as? Data else { throw KeychainReadError.malformed }
        return data
      case errSecItemNotFound:
        throw KeychainReadError.notFound
      default:
        throw KeychainReadError.unavailable
      }
    }
  #endif
}

public enum CodexUsageParser {
  public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

  public static func makeRequest(accessToken: String, accountID: String? = nil) -> URLRequest {
    var request = URLRequest(
      url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("AgentMeter/1.0", forHTTPHeaderField: "User-Agent")
    if let accountID, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
    }
    return request
  }

  public static func parse(data: Data, now: Date = Date()) throws -> ProviderUsage {
    guard let root = try? JSONSupport.object(from: data) else {
      throw UsageParsingError.invalidSchema(.codex)
    }
    guard let rawRateLimit = root["rate_limit"] else {
      return ProviderUsage(provider: .codex, windows: [], updatedAt: now)
    }
    if rawRateLimit is NSNull {
      return ProviderUsage(provider: .codex, windows: [], updatedAt: now)
    }
    guard let rateLimit = rawRateLimit as? [String: Any] else {
      throw UsageParsingError.invalidSchema(.codex)
    }

    var windows: [UsageWindow] = []
    if let primary = try parseWindow(
      rateLimit["primary_window"], id: "codex-primary")
    {
      windows.append(primary)
    }
    if let secondary = try parseWindow(
      rateLimit["secondary_window"], id: "codex-secondary")
    {
      windows.append(secondary)
    }
    return ProviderUsage(provider: .codex, windows: windows, updatedAt: now)
  }

  private static func parseWindow(_ raw: Any?, id: String) throws -> UsageWindow? {
    guard let raw else { return nil }
    if raw is NSNull { return nil }
    guard let object = raw as? [String: Any] else {
      throw UsageParsingError.invalidSchema(.codex)
    }
    guard let rawUsed = object["used_percent"] else { return nil }
    if rawUsed is NSNull { return nil }
    guard let used = JSONSupport.number(rawUsed), used >= 0 else {
      throw UsageParsingError.invalidSchema(.codex)
    }

    var resetAt: Date?
    if let rawReset = object["reset_at"], !(rawReset is NSNull) {
      guard let epoch = JSONSupport.number(rawReset), epoch >= 0 else {
        throw UsageParsingError.invalidSchema(.codex)
      }
      let seconds = epoch > 100_000_000_000 ? epoch / 1_000 : epoch
      resetAt = Date(timeIntervalSince1970: seconds)
    }
    var duration: Double?
    if let rawDuration = object["limit_window_seconds"], !(rawDuration is NSNull) {
      guard let parsedDuration = JSONSupport.number(rawDuration), parsedDuration >= 0 else {
        throw UsageParsingError.invalidSchema(.codex)
      }
      guard parsedDuration <= Double(Int.max) else {
        throw UsageParsingError.invalidSchema(.codex)
      }
      duration = parsedDuration
    }
    return UsageWindow(
      id: id,
      title: title(for: duration, id: id),
      remainingPercent: 100 - used,
      resetAt: resetAt)
  }

  private static func title(for duration: Double?, id: String) -> String {
    guard let duration, duration > 0, duration.isFinite else {
      return id == "codex-primary" ? "기본 한도" : "보조 한도"
    }
    let seconds = Int(duration.rounded())
    if seconds == 18_000 { return "5시간 세션" }
    if seconds == 604_800 { return "7일 주간" }
    if seconds % 604_800 == 0 { return "\(seconds / 604_800)일 한도" }
    if seconds % 3_600 == 0 { return "\(seconds / 3_600)시간 한도" }
    if seconds % 60 == 0 { return "\(seconds / 60)분 한도" }
    return "\(seconds)초 한도"
  }
}

public enum ClaudeUsageParser {
  public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  public static let anthropicBetaHeader = "oauth-2025-04-20"

  public static func makeRequest(accessToken: String) -> URLRequest {
    var request = URLRequest(
      url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
    request.httpMethod = "GET"
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(anthropicBetaHeader, forHTTPHeaderField: "anthropic-beta")
    request.setValue("AgentMeter/1.0", forHTTPHeaderField: "User-Agent")
    return request
  }

  public static func parse(data: Data, now: Date = Date()) throws -> ProviderUsage {
    guard let root = try? JSONSupport.object(from: data) else {
      throw UsageParsingError.invalidSchema(.claude)
    }
    var windows: [UsageWindow] = []
    if let fiveHour = try parseWindow(
      root["five_hour"], id: "claude-five-hour", title: "5시간 세션")
    {
      windows.append(fiveHour)
    }
    if let sevenDay = try parseWindow(
      root["seven_day"], id: "claude-seven-day", title: "7일 주간")
    {
      windows.append(sevenDay)
    }
    windows.append(contentsOf: try parseFableWindows(root["limits"]))
    return ProviderUsage(provider: .claude, windows: windows, updatedAt: now)
  }

  public static func parseISO8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private static func parseWindow(_ raw: Any?, id: String, title: String) throws -> UsageWindow? {
    guard let raw else { return nil }
    if raw is NSNull { return nil }
    guard let object = raw as? [String: Any] else {
      throw UsageParsingError.invalidSchema(.claude)
    }
    guard let utilization = try parseUtilization(object["utilization"]) else { return nil }

    var resetAt: Date?
    if let rawReset = object["resets_at"], !(rawReset is NSNull) {
      guard let value = rawReset as? String,
        let date = parseISO8601(value.trimmingCharacters(in: .whitespacesAndNewlines))
      else {
        throw UsageParsingError.invalidSchema(.claude)
      }
      resetAt = date
    }
    return UsageWindow(id: id, title: title, remainingPercent: 100 - utilization, resetAt: resetAt)
  }

  private static func parseFableWindows(_ raw: Any?) throws -> [UsageWindow] {
    guard let raw else { return [] }
    if raw is NSNull { return [] }
    guard let limits = raw as? [Any] else {
      throw UsageParsingError.invalidSchema(.claude)
    }

    var windows: [UsageWindow] = []
    var fableIndex = 0
    for rawLimit in limits {
      guard let limit = rawLimit as? [String: Any] else {
        throw UsageParsingError.invalidSchema(.claude)
      }
      guard JSONSupport.string(limit["kind"]) == "weekly_scoped",
        JSONSupport.string(limit["group"]) == "weekly",
        let scope = limit["scope"] as? [String: Any],
        let model = scope["model"] as? [String: Any],
        let displayName = JSONSupport.string(model["display_name"]),
        displayName.caseInsensitiveCompare("Fable") == .orderedSame
      else {
        continue
      }

      guard let utilization = try parseUtilization(limit["percent"]) else { continue }

      var resetAt: Date?
      if let rawReset = limit["resets_at"], !(rawReset is NSNull) {
        guard let value = rawReset as? String,
          let date = parseISO8601(value.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
          throw UsageParsingError.invalidSchema(.claude)
        }
        resetAt = date
      }

      fableIndex += 1
      let id = fableIndex == 1 ? "claude-fable-weekly" : "claude-fable-weekly-\(fableIndex)"
      windows.append(
        UsageWindow(
          id: id,
          title: "Fable 7일 주간",
          remainingPercent: 100 - utilization,
          resetAt: resetAt))
    }
    return windows
  }

  private static func parseUtilization(_ raw: Any?) throws -> Double? {
    guard let raw, !(raw is NSNull) else { return nil }
    guard let utilization = JSONSupport.number(raw), utilization >= 0 else {
      throw UsageParsingError.invalidSchema(.claude)
    }
    return utilization
  }
}

public struct HTTPResponse: Sendable, Equatable {
  public let statusCode: Int
  public let data: Data
  public let headers: [String: String]

  public init(statusCode: Int, data: Data = Data(), headers: [String: String] = [:]) {
    self.statusCode = statusCode
    self.data = data
    self.headers = headers
  }

  public func value(forHTTPHeaderField field: String) -> String? {
    let key = field.lowercased()
    return headers.first { $0.key.lowercased() == key }?.value
  }
}

public protocol UsageHTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> HTTPResponse
}

private final class RedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public final class URLSessionHTTPTransport: UsageHTTPTransport, @unchecked Sendable {
  private let session: URLSession
  private let redirectDelegate: RedirectBlockingDelegate

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    let redirectDelegate = RedirectBlockingDelegate()
    self.redirectDelegate = redirectDelegate
    self.session = URLSession(
      configuration: configuration,
      delegate: redirectDelegate,
      delegateQueue: nil)
  }

  deinit {
    session.invalidateAndCancel()
  }

  public func send(_ request: URLRequest) async throws -> HTTPResponse {
    do {
      let (data, response) = try await session.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw UsageTransportError.invalidResponse
      }
      var headers: [String: String] = [:]
      for (key, value) in response.allHeaderFields {
        if let key = key as? String {
          headers[key] = String(describing: value)
        }
      }
      return HTTPResponse(statusCode: response.statusCode, data: data, headers: headers)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as UsageTransportError {
      throw error
    } catch {
      throw UsageTransportError.connectionFailed
    }
  }
}

public actor UsageService {
  private struct RateLimitState {
    var failures: Int
    var blockedUntil: Date
  }

  private let credentialReader: any CredentialReader
  private let transport: any UsageHTTPTransport
  private var consentGranted = false
  private var rateLimits: [Provider: RateLimitState] = [:]

  public init(
    credentialReader: any CredentialReader = LocalCredentialReader(),
    transport: any UsageHTTPTransport = URLSessionHTTPTransport()
  ) {
    self.credentialReader = credentialReader
    self.transport = transport
  }

  public func setConsent(_ granted: Bool) {
    consentGranted = granted
    if !granted { rateLimits.removeAll() }
  }

  public func hasConsent() -> Bool { consentGranted }

  public func nextRetryAt(for provider: Provider, now: Date = Date()) -> Date? {
    guard let blockedUntil = rateLimits[provider]?.blockedUntil, blockedUntil > now else {
      return nil
    }
    return blockedUntil
  }

  public func fetch(_ provider: Provider, now: Date = Date()) async throws -> ProviderUsage {
    guard consentGranted else { throw UsageFetchError.consentRequired }
    if let blockedUntil = rateLimits[provider]?.blockedUntil, blockedUntil > now {
      throw UsageFetchError.rateLimited(provider, retryAt: blockedUntil)
    }

    let request: URLRequest
    do {
      switch provider {
      case .codex:
        let credentials = try credentialReader.readCodexCredentials()
        request = CodexUsageParser.makeRequest(
          accessToken: credentials.accessToken,
          accountID: credentials.accountID)
      case .claude:
        let credentials = try credentialReader.readClaudeCredentials()
        request = ClaudeUsageParser.makeRequest(accessToken: credentials.accessToken)
      }
    } catch let error as CredentialError {
      throw Self.mapCredentialError(error, provider: provider)
    } catch {
      throw UsageFetchError.invalidCredentials(provider)
    }

    let response: HTTPResponse
    do {
      response = try await transport.send(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw UsageFetchError.network(provider)
    }

    switch response.statusCode {
    case 200:
      do {
        let usage: ProviderUsage
        switch provider {
        case .codex:
          usage = try CodexUsageParser.parse(data: response.data, now: now)
        case .claude:
          usage = try ClaudeUsageParser.parse(data: response.data, now: now)
        }
        rateLimits.removeValue(forKey: provider)
        return usage
      } catch {
        throw UsageFetchError.invalidResponse(provider)
      }
    case 401:
      throw UsageFetchError.unauthorized(provider)
    case 403:
      throw UsageFetchError.forbidden(provider)
    case 429:
      let failureCount = (rateLimits[provider]?.failures ?? 0) + 1
      let fallbackDelay = Self.backoffDelay(forFailure: failureCount)
      let requestedRetry = Self.retryAfterDate(from: response, now: now)
      let delay: TimeInterval
      if let requestedRetry {
        let requestedDelay = requestedRetry.timeIntervalSince(now)
        delay = requestedDelay > 0 ? requestedDelay : fallbackDelay
      } else {
        delay = fallbackDelay
      }
      let blockedUntil = now.addingTimeInterval(delay)
      rateLimits[provider] = RateLimitState(failures: failureCount, blockedUntil: blockedUntil)
      throw UsageFetchError.rateLimited(provider, retryAt: blockedUntil)
    default:
      throw UsageFetchError.serverError(provider, statusCode: response.statusCode)
    }
  }

  private static func mapCredentialError(_ error: CredentialError, provider: Provider)
    -> UsageFetchError
  {
    switch error {
    case .missing:
      .missingCredentials(provider)
    case .invalid:
      .invalidCredentials(provider)
    case .expired:
      .expiredCredentials(provider)
    case .keychainUnavailable:
      .keychainUnavailable
    }
  }

  private static func backoffDelay(forFailure failure: Int) -> TimeInterval {
    let exponent = min(max(failure - 1, 0), 5)
    let multiplier = 1 << exponent
    return TimeInterval(min(900, 30 * multiplier))
  }

  public static func retryAfterDate(from response: HTTPResponse, now: Date = Date()) -> Date? {
    guard
      let value = response.value(forHTTPHeaderField: "Retry-After")?
        .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
      return now.addingTimeInterval(seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    return formatter.date(from: value)
  }
}
