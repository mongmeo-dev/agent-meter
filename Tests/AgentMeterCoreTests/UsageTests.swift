import XCTest

@testable import AgentMeterCore

final class UsageTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  func testCodexFixtureParsesRemainingPercentAndResetTimes() throws {
    let data = Data(
      """
      {
        "account_id": "acct_test",
        "rate_limit": {
          "primary_window": {
            "used_percent": 25,
            "reset_at": 1700003600,
            "limit_window_seconds": 18000
          },
          "secondary_window": {
            "used_percent": 40.5,
            "reset_at": 1700604800,
            "limit_window_seconds": 604800
          }
        }
      }
      """.utf8)

    let usage = try CodexUsageParser.parse(data: data, now: now)

    XCTAssertEqual(usage.provider, .codex)
    XCTAssertEqual(usage.windows.map(\.id), ["codex-primary", "codex-secondary"])
    XCTAssertEqual(usage.windows[0].remainingPercent, 75, accuracy: 0.001)
    XCTAssertEqual(usage.windows[1].remainingPercent, 59.5, accuracy: 0.001)
    XCTAssertEqual(usage.windows[0].resetAt, Date(timeIntervalSince1970: 1_700_003_600))
    XCTAssertEqual(usage.windows[1].resetAt, Date(timeIntervalSince1970: 1_700_604_800))
    XCTAssertEqual(usage.windows[0].title, "5시간 세션")
    XCTAssertEqual(usage.windows[1].title, "7일 주간")
  }

  func testCodexZeroAndOnePercentUsageRemainNumeric() throws {
    let data = Data(
      """
      {
        "rate_limit": {
          "primary_window": {"used_percent": 0, "limit_window_seconds": 18000},
          "secondary_window": {"used_percent": 1, "limit_window_seconds": 7200}
        }
      }
      """.utf8)

    let usage = try CodexUsageParser.parse(data: data, now: now)

    XCTAssertEqual(usage.windows[0].remainingPercent, 100, accuracy: 0.001)
    XCTAssertEqual(usage.windows[1].remainingPercent, 99, accuracy: 0.001)
    XCTAssertEqual(usage.windows[1].title, "2시간 한도")
  }

  func testClaudeFixtureParsesRemainingPercentAndISO8601ResetTimes() throws {
    let data = Data(
      """
      {
        "five_hour": {
          "utilization": 34.5,
          "resets_at": "2024-01-15T12:34:56.123Z"
        },
        "seven_day": {
          "utilization": 80,
          "resets_at": "2024-01-21T00:00:00Z"
        }
      }
      """.utf8)

    let usage = try ClaudeUsageParser.parse(data: data, now: now)

    XCTAssertEqual(usage.provider, .claude)
    XCTAssertEqual(usage.windows.map(\.id), ["claude-five-hour", "claude-seven-day"])
    XCTAssertEqual(usage.windows[0].remainingPercent, 65.5, accuracy: 0.001)
    XCTAssertEqual(usage.windows[1].remainingPercent, 20, accuracy: 0.001)
    XCTAssertEqual(
      usage.windows[0].resetAt,
      ClaudeUsageParser.parseISO8601("2024-01-15T12:34:56.123Z"))
  }

  func testClaudeActiveFableLimitAppendsAfterBaseWindows() throws {
    let data = Data(
      """
      {
        "five_hour": {"utilization": 10},
        "seven_day": {"utilization": 20},
        "limits": [
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 34.5,
            "resets_at": "2024-01-22T00:00:00.123Z",
            "scope": {"model": {"id": "fable-model", "display_name": "  fAbLe  "}},
            "is_active": true
          }
        ]
      }
      """.utf8)

    let usage = try ClaudeUsageParser.parse(data: data, now: now)

    XCTAssertEqual(
      usage.windows.map(\.id),
      ["claude-five-hour", "claude-seven-day", "claude-fable-weekly"])
    XCTAssertEqual(usage.windows[2].title, "Fable 7일 주간")
    XCTAssertEqual(usage.windows[2].remainingPercent, 65.5, accuracy: 0.001)
    XCTAssertEqual(
      usage.windows[2].resetAt,
      ClaudeUsageParser.parseISO8601("2024-01-22T00:00:00.123Z"))
  }

  func testClaudeFableLimitCanBeParsedWithoutBaseWindows() throws {
    let data = Data(
      """
      {
        "limits": [
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 12.25,
            "scope": {"model": {"display_name": "FABLE"}}
          }
        ]
      }
      """.utf8)

    let usage = try ClaudeUsageParser.parse(data: data, now: now)

    XCTAssertEqual(usage.windows.map(\.id), ["claude-fable-weekly"])
    XCTAssertEqual(usage.windows[0].remainingPercent, 87.75, accuracy: 0.001)
    XCTAssertNil(usage.windows[0].resetAt)
  }

  func testClaudeFableLimitsSkipNonFableEntries() throws {
    let data = Data(
      """
      {
        "limits": [
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": true,
            "scope": {"model": {"id": "sonnet", "display_name": "Sonnet"}}
          },
          {
            "kind": "monthly_scoped",
            "group": "weekly",
            "percent": -1,
            "scope": {"model": {"id": "fable", "display_name": "Fable"}}
          },
          {
            "kind": "weekly_scoped",
            "group": "daily",
            "percent": 10,
            "scope": {"model": {"id": "fable", "display_name": "Fable"}}
          },
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 10,
            "scope": {"model": {"id": "Fable", "display_name": "Sonnet"}}
          }
        ]
      }
      """.utf8)

    let usage = try ClaudeUsageParser.parse(data: data, now: now)

    XCTAssertTrue(usage.windows.isEmpty)
  }

  func testClaudeInactiveFableLimitWithNullModelIDIsStillShown() throws {
    let data = Data(
      """
      {
        "limits": [
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 11,
            "scope": {"model": {"id": null, "display_name": "Fable"}},
            "is_active": false
          }
        ]
      }
      """.utf8)

    let usage = try ClaudeUsageParser.parse(data: data, now: now)

    XCTAssertEqual(usage.windows.map(\.id), ["claude-fable-weekly"])
    XCTAssertEqual(usage.windows[0].title, "Fable 7일 주간")
    XCTAssertEqual(usage.windows[0].remainingPercent, 89, accuracy: 0.001)
  }

  func testClaudeFableMissingAndNullPercentDoNotFabricateWindows() throws {
    let data = Data(
      """
      {
        "limits": [
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "scope": {"model": {"display_name": "Fable"}}
          },
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": null,
            "scope": {"model": {"display_name": "Fable"}}
          }
        ]
      }
      """.utf8)

    let usage = try ClaudeUsageParser.parse(data: data, now: now)

    XCTAssertTrue(usage.windows.isEmpty)
  }

  func testClaudeFableMalformedPercentFailsClosed() {
    for percent in ["true", "-0.1"] {
      let data = Data(
        """
        {
          "limits": [{
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": \(percent),
            "scope": {"model": {"display_name": "Fable"}}
          }]
        }
        """.utf8)

      XCTAssertThrowsError(try ClaudeUsageParser.parse(data: data, now: now)) { error in
        XCTAssertEqual(error as? UsageParsingError, .invalidSchema(.claude))
      }
    }
  }

  func testClaudeFableZeroAndOnePercentRemainNumeric() throws {
    let data = Data(
      """
      {
        "limits": [
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 0,
            "scope": {"model": {"display_name": "Fable"}}
          },
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 1,
            "scope": {"model": {"display_name": "Fable"}}
          }
        ]
      }
      """.utf8)

    let usage = try ClaudeUsageParser.parse(data: data, now: now)

    XCTAssertEqual(usage.windows.map(\.remainingPercent), [100, 99])
  }

  func testClaudeFableLimitResetDateMustBeValidISO8601() throws {
    let valid = Data(
      """
      {
        "limits": [{
          "kind": "weekly_scoped",
          "group": "weekly",
          "percent": 25.25,
          "resets_at": "2024-01-22T00:00:00Z",
          "scope": {"model": {"display_name": "Fable"}}
        }]
      }
      """.utf8)
    let validUsage = try ClaudeUsageParser.parse(data: valid, now: now)
    XCTAssertEqual(
      validUsage.windows[0].resetAt,
      ClaudeUsageParser.parseISO8601("2024-01-22T00:00:00Z"))
    XCTAssertEqual(validUsage.windows[0].remainingPercent, 74.75, accuracy: 0.001)

    let invalid = Data(
      """
      {
        "limits": [{
          "kind": "weekly_scoped",
          "group": "weekly",
          "percent": 25,
          "resets_at": "not-a-date",
          "scope": {"model": {"display_name": "Fable"}}
        }]
      }
      """.utf8)
    XCTAssertThrowsError(try ClaudeUsageParser.parse(data: invalid, now: now)) { error in
      XCTAssertEqual(error as? UsageParsingError, .invalidSchema(.claude))
    }
  }

  func testClaudeFableLimitIDsAreUniqueForMultipleEntries() throws {
    let data = Data(
      """
      {
        "limits": [
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 10,
            "scope": {"model": {"id": "first", "display_name": "Fable"}}
          },
          {
            "kind": "weekly_scoped",
            "group": "weekly",
            "percent": 20,
            "scope": {"model": {"id": "second", "display_name": "fable"}}
          }
        ]
      }
      """.utf8)

    let usage = try ClaudeUsageParser.parse(data: data, now: now)

    XCTAssertEqual(usage.windows.map(\.id), ["claude-fable-weekly", "claude-fable-weekly-2"])
    XCTAssertEqual(Set(usage.windows.map(\.id)).count, 2)
  }

  func testRemainingLevelThresholds() {
    XCTAssertEqual(RemainingLevel(remainingPercent: 100), .normal)
    XCTAssertEqual(RemainingLevel(remainingPercent: 25.1), .normal)
    XCTAssertEqual(RemainingLevel(remainingPercent: 25), .low)
    XCTAssertEqual(RemainingLevel(remainingPercent: 10.1), .low)
    XCTAssertEqual(RemainingLevel(remainingPercent: 10), .critical)
    XCTAssertEqual(RemainingLevel(remainingPercent: 0), .critical)
    XCTAssertEqual(
      UsageWindow(id: "w", title: "t", remainingPercent: 5, resetAt: nil).level, .critical)
  }

  func testCodexCreditsParseBalanceEvenWithoutRateLimit() throws {
    let data = Data(
      """
      {
        "credits": {"has_credits": true, "unlimited": false, "balance": "12.5"}
      }
      """.utf8)

    let usage = try CodexUsageParser.parse(data: data, now: now)

    XCTAssertTrue(usage.windows.isEmpty)
    XCTAssertEqual(usage.credits, CreditBalance(remaining: 12.5))
  }

  func testCodexUnlimitedAndMalformedCredits() throws {
    let unlimited = try CodexUsageParser.parse(
      data: Data("{\"credits\":{\"unlimited\":true,\"balance\":null}}".utf8), now: now)
    XCTAssertEqual(unlimited.credits, CreditBalance(remaining: 0, isUnlimited: true))

    let malformed = try CodexUsageParser.parse(
      data: Data("{\"credits\":{\"balance\":\"abc\"}}".utf8), now: now)
    XCTAssertNil(malformed.credits)
  }

  func testClaudeExtraUsageCreditsAreRemainingMonthlyLimitInDollars() throws {
    let data = Data(
      """
      {
        "five_hour": {"utilization": 10},
        "extra_usage": {
          "is_enabled": true,
          "monthly_limit": 5000,
          "used_credits": 1234.0,
          "utilization": 24.68
        }
      }
      """.utf8)

    let usage = try ClaudeUsageParser.parse(data: data, now: now)

    XCTAssertEqual(usage.credits?.currencyCode, "USD")
    XCTAssertEqual(usage.credits?.remaining ?? -1, 37.66, accuracy: 0.001)
    XCTAssertEqual(usage.credits?.isUnlimited, false)
  }

  func testClaudeExtraUsageDisabledOrUnlimited() throws {
    let disabled = try ClaudeUsageParser.parse(
      data: Data("{\"extra_usage\":{\"is_enabled\":false,\"monthly_limit\":5000}}".utf8),
      now: now)
    XCTAssertNil(disabled.credits)

    let unlimited = try ClaudeUsageParser.parse(
      data: Data(
        "{\"extra_usage\":{\"is_enabled\":true,\"monthly_limit\":null,\"used_credits\":10}}".utf8),
      now: now)
    XCTAssertEqual(
      unlimited.credits, CreditBalance(remaining: 0, currencyCode: "USD", isUnlimited: true))
  }

  func testCachedUsageWithoutCreditsStillDecodes() throws {
    let data = Data(
      """
      {"provider": "codex", "windows": [], "updatedAt": 0}
      """.utf8)

    let usage = try JSONDecoder().decode(ProviderUsage.self, from: data)

    XCTAssertNil(usage.credits)
  }

  func testMissingLimitsAreUnavailableRatherThanFull() throws {
    let codex = try CodexUsageParser.parse(data: Data("{}".utf8), now: now)
    let claude = try ClaudeUsageParser.parse(
      data: Data("{\"five_hour\":null,\"seven_day\":{\"utilization\":null}}".utf8),
      now: now)
    let claudeWithNullLimits = try ClaudeUsageParser.parse(
      data: Data("{\"limits\":null}".utf8), now: now)

    XCTAssertTrue(codex.windows.isEmpty)
    XCTAssertTrue(claude.windows.isEmpty)
    XCTAssertTrue(claudeWithNullLimits.windows.isEmpty)
  }

  func testMalformedLimitSchemaFailsClosed() {
    XCTAssertThrowsError(
      try CodexUsageParser.parse(
        data: Data("{\"rate_limit\":{\"primary_window\":[]}}".utf8),
        now: now)
    ) { error in
      XCTAssertEqual(error as? UsageParsingError, .invalidSchema(.codex))
    }
    XCTAssertThrowsError(
      try ClaudeUsageParser.parse(
        data: Data("{\"five_hour\":[]}".utf8),
        now: now)
    ) { error in
      XCTAssertEqual(error as? UsageParsingError, .invalidSchema(.claude))
    }
  }

  func testRequestBuildersUseFixedTrustedEndpointsAndRequiredHeaders() {
    let codex = CodexUsageParser.makeRequest(accessToken: "token", accountID: "account")
    XCTAssertEqual(codex.url, CodexUsageParser.endpoint)
    XCTAssertEqual(codex.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    XCTAssertEqual(codex.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account")

    let claude = ClaudeUsageParser.makeRequest(accessToken: "token")
    XCTAssertEqual(claude.url, ClaudeUsageParser.endpoint)
    XCTAssertEqual(claude.value(forHTTPHeaderField: "Authorization"), "Bearer token")
    XCTAssertEqual(
      claude.value(forHTTPHeaderField: "anthropic-beta"),
      ClaudeUsageParser.anthropicBetaHeader)
  }

  func testConsentPreventsCredentialAndNetworkAccess() async {
    let reader = StubCredentialReader()
    let transport = StubTransport(
      result: .success(HTTPResponse(statusCode: 200, data: Data("{}".utf8))))
    let service = UsageService(credentialReader: reader, transport: transport)

    do {
      _ = try await service.fetch(.codex, now: now)
      XCTFail("consent must be required")
    } catch let error as UsageFetchError {
      XCTAssertEqual(error, .consentRequired)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(reader.codexReads, 0)
    XCTAssertEqual(transport.requests.count, 0)
  }

  func testHTTP401And403AreProviderErrorsWithoutBodyDetails() async {
    for status in [401, 403] {
      let reader = StubCredentialReader()
      let transport = StubTransport(
        result: .success(
          HTTPResponse(
            statusCode: status,
            data: Data("secret response body".utf8))))
      let service = UsageService(credentialReader: reader, transport: transport)
      await service.setConsent(true)

      do {
        _ = try await service.fetch(.codex, now: now)
        XCTFail("HTTP \(status) must fail")
      } catch let error as UsageFetchError {
        if status == 401 {
          XCTAssertEqual(error, .unauthorized(.codex))
        } else {
          XCTAssertEqual(error, .forbidden(.codex))
        }
        XCTAssertFalse(error.userMessage.contains("secret response body"))
      } catch {
        XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testRateLimitRetryAfterBlocksManualRefreshAndUsesHeader() async {
    let reader = StubCredentialReader()
    let transport = StubTransport(
      result: .success(
        HTTPResponse(
          statusCode: 429,
          headers: ["Retry-After": "60"])))
    let service = UsageService(credentialReader: reader, transport: transport)
    await service.setConsent(true)

    do {
      _ = try await service.fetch(.codex, now: now)
      XCTFail("HTTP 429 must fail")
    } catch let error as UsageFetchError {
      guard case .rateLimited(.codex, let retryDate) = error,
        let retryAt = retryDate
      else {
        return XCTFail("expected rate limit")
      }
      XCTAssertEqual(retryAt, now.addingTimeInterval(60))
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    do {
      _ = try await service.fetch(.codex, now: now.addingTimeInterval(30))
      XCTFail("manual refresh must honor Retry-After")
    } catch let error as UsageFetchError {
      guard case .rateLimited(.codex, let retryAt) = error else {
        return XCTFail("expected blocked rate limit")
      }
      XCTAssertEqual(retryAt, now.addingTimeInterval(60))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertEqual(transport.requests.count, 1)
  }

  func testRateLimitWithoutHeaderUsesExponentialBackoff() async {
    let reader = StubCredentialReader()
    let transport = StubTransport(result: .success(HTTPResponse(statusCode: 429)))
    let service = UsageService(credentialReader: reader, transport: transport)
    await service.setConsent(true)

    do {
      _ = try await service.fetch(.codex, now: now)
      XCTFail("HTTP 429 must fail")
    } catch let error as UsageFetchError {
      guard case .rateLimited(_, let retryAt) = error, let retryAt else {
        return XCTFail("expected retry date")
      }
      XCTAssertEqual(retryAt.timeIntervalSince(now), 30, accuracy: 0.001)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testClaudeSuccessIsReusedUntilMinimumIntervalElapses() async throws {
    let reader = StubCredentialReader()
    let transport = StubTransport(
      result: .success(HTTPResponse(statusCode: 200, data: claudeUsageBody)))
    let service = UsageService(credentialReader: reader, transport: transport)
    await service.setConsent(true)

    let first = try await service.fetch(.claude, now: now)
    let cached = try await service.fetch(.claude, now: now.addingTimeInterval(589))
    XCTAssertEqual(cached, first)
    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertEqual(reader.claudeReads, 1)

    let refreshed = try await service.fetch(.claude, now: now.addingTimeInterval(590))
    XCTAssertEqual(refreshed.updatedAt, now.addingTimeInterval(590))
    XCTAssertEqual(transport.requests.count, 2)
  }

  func testCodexIsNotPacedBetweenSuccessfulRequests() async throws {
    let transport = StubTransport(
      result: .success(HTTPResponse(statusCode: 200, data: Data("{}".utf8))))
    let service = UsageService(credentialReader: StubCredentialReader(), transport: transport)
    await service.setConsent(true)

    _ = try await service.fetch(.codex, now: now)
    _ = try await service.fetch(.codex, now: now.addingTimeInterval(1))
    XCTAssertEqual(transport.requests.count, 2)
  }

  func testClaudeRateLimitNeverRetriesSoonerThanMinimumBackoff() async {
    for (header, expectedDelay) in [("60", 600.0), ("1362", 1_362.0), ("999999", 86_400.0)] {
      let transport = StubTransport(
        result: .success(HTTPResponse(statusCode: 429, headers: ["retry-after": header])))
      let service = UsageService(credentialReader: StubCredentialReader(), transport: transport)
      await service.setConsent(true)

      let retryAt = now.addingTimeInterval(expectedDelay)
      await assertFetchError(service, .claude, at: now) { error in
        XCTAssertEqual(error, .rateLimited(.claude, retryAt: retryAt))
      }
      await assertFetchError(service, .claude, at: retryAt.addingTimeInterval(-1)) { error in
        XCTAssertEqual(error, .rateLimited(.claude, retryAt: retryAt))
      }
      XCTAssertEqual(transport.requests.count, 1, "Retry-After \(header)")
    }
  }

  func testClaudeRateLimitWithoutHeaderBacksOffFromMinimum() async {
    let transport = StubTransport(result: .success(HTTPResponse(statusCode: 429)))
    let service = UsageService(credentialReader: StubCredentialReader(), transport: transport)
    await service.setConsent(true)

    await assertFetchError(service, .claude, at: now) { error in
      XCTAssertEqual(error, .rateLimited(.claude, retryAt: self.now.addingTimeInterval(600)))
    }
    let second = now.addingTimeInterval(600)
    await assertFetchError(service, .claude, at: second) { error in
      XCTAssertEqual(error, .rateLimited(.claude, retryAt: second.addingTimeInterval(1_200)))
    }
    XCTAssertEqual(transport.requests.count, 2)
  }

  func testRateLimitCooldownSurvivesServiceRestartAndConsentRevocation() async {
    let store = InMemoryUsageRequestStore()
    let firstTransport = StubTransport(
      result: .success(HTTPResponse(statusCode: 429, headers: ["Retry-After": "1200"])))
    let first = UsageService(
      credentialReader: StubCredentialReader(), transport: firstTransport, store: store)
    await first.setConsent(true)
    await assertFetchError(first, .claude, at: now) { _ in }

    let secondTransport = StubTransport(
      result: .success(HTTPResponse(statusCode: 200, data: claudeUsageBody)))
    let second = UsageService(
      credentialReader: StubCredentialReader(), transport: secondTransport, store: store)
    await second.setConsent(true)
    await second.setConsent(false)
    await second.setConsent(true)
    await assertFetchError(second, .claude, at: now.addingTimeInterval(1_199)) { error in
      XCTAssertEqual(error, .rateLimited(.claude, retryAt: self.now.addingTimeInterval(1_200)))
    }
    XCTAssertEqual(secondTransport.requests.count, 0)

    _ = try? await second.fetch(.claude, now: now.addingTimeInterval(1_200))
    XCTAssertEqual(secondTransport.requests.count, 1)
    XCTAssertEqual(store.load(.claude)?.blockedUntil, nil)
    XCTAssertEqual(store.load(.claude)?.rateLimitFailures, 0)
  }

  func testCachedClaudeUsageSurvivesRestartButNotConsentRevocation() async throws {
    let store = InMemoryUsageRequestStore()
    let transport = StubTransport(
      result: .success(HTTPResponse(statusCode: 200, data: claudeUsageBody)))
    let first = UsageService(
      credentialReader: StubCredentialReader(), transport: transport, store: store)
    await first.setConsent(true)
    let usage = try await first.fetch(.claude, now: now)

    let second = UsageService(
      credentialReader: StubCredentialReader(), transport: transport, store: store)
    await second.setConsent(true)
    let restored = await second.cachedUsage(for: .claude)
    XCTAssertEqual(restored, usage)
    let fetched = try await second.fetch(.claude, now: now.addingTimeInterval(60))
    XCTAssertEqual(fetched, usage)
    XCTAssertEqual(transport.requests.count, 1)

    await second.setConsent(false)
    await second.setConsent(true)
    let cleared = await second.cachedUsage(for: .claude)
    XCTAssertNil(cleared)
    XCTAssertNil(store.load(.claude)?.cachedUsage)
  }

  func testClaudeFailureSpacesOutRetries() async {
    let transport = StubTransport(result: .success(HTTPResponse(statusCode: 500)))
    let service = UsageService(credentialReader: StubCredentialReader(), transport: transport)
    await service.setConsent(true)

    await assertFetchError(service, .claude, at: now) { error in
      XCTAssertEqual(error, .serverError(.claude, statusCode: 500))
    }
    await assertFetchError(service, .claude, at: now.addingTimeInterval(59)) { error in
      XCTAssertEqual(error, .requestThrottled(.claude, retryAt: self.now.addingTimeInterval(60)))
      XCTAssertEqual(error.retryAt, self.now.addingTimeInterval(60))
    }
    XCTAssertEqual(transport.requests.count, 1)

    await assertFetchError(service, .claude, at: now.addingTimeInterval(60)) { error in
      XCTAssertEqual(error, .serverError(.claude, statusCode: 500))
    }
    XCTAssertEqual(transport.requests.count, 2)
  }

  func testUserDefaultsRequestStoreRoundTripsRecord() throws {
    let suiteName = "AgentMeterTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = UserDefaultsUsageRequestStore(defaults: defaults)
    let usage = try ClaudeUsageParser.parse(data: claudeUsageBody, now: now)
    let record = UsageRequestRecord(
      cachedUsage: usage,
      lastFailureAt: now,
      rateLimitFailures: 2,
      blockedUntil: now.addingTimeInterval(600))

    store.save(record, for: .claude)

    XCTAssertEqual(UserDefaultsUsageRequestStore(defaults: defaults).load(.claude), record)
    XCTAssertNil(store.load(.codex))
  }

  private var claudeUsageBody: Data {
    Data(
      """
      {
        "five_hour": {"utilization": 25, "resets_at": "2023-11-14T23:13:20Z"},
        "seven_day": {"utilization": 40, "resets_at": "2023-11-20T00:00:00Z"}
      }
      """.utf8)
  }

  private func assertFetchError(
    _ service: UsageService,
    _ provider: Provider,
    at date: Date,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ check: (UsageFetchError) -> Void
  ) async {
    do {
      _ = try await service.fetch(provider, now: date)
      XCTFail("fetch must fail", file: file, line: line)
    } catch let error as UsageFetchError {
      check(error)
    } catch {
      XCTFail("unexpected error: \(error)", file: file, line: line)
    }
  }

  func testNetworkFailureIsSanitized() async {
    let reader = StubCredentialReader()
    let transport = StubTransport(result: .failure(.connectionFailed))
    let service = UsageService(credentialReader: reader, transport: transport)
    await service.setConsent(true)

    do {
      _ = try await service.fetch(.codex, now: now)
      XCTFail("network failure must fail")
    } catch let error as UsageFetchError {
      XCTAssertEqual(error, .network(.codex))
      XCTAssertFalse(error.userMessage.contains("token"))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }
}

private final class StubCredentialReader: CredentialReader, @unchecked Sendable {
  let codexCredentials = CodexCredentials(accessToken: "codex-test", accountID: "account-test")
  let claudeCredentials = ClaudeCredentials(accessToken: "claude-test")
  var codexReads = 0
  var claudeReads = 0

  func readCodexCredentials() throws -> CodexCredentials {
    codexReads += 1
    return codexCredentials
  }

  func readClaudeCredentials() throws -> ClaudeCredentials {
    claudeReads += 1
    return claudeCredentials
  }
}

private final class StubTransport: UsageHTTPTransport, @unchecked Sendable {
  let result: Result<HTTPResponse, UsageTransportError>
  var requests: [URLRequest] = []

  init(result: Result<HTTPResponse, UsageTransportError>) {
    self.result = result
  }

  func send(_ request: URLRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try result.get()
  }
}
