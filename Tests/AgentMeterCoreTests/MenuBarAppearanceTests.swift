import XCTest

@testable import AgentMeterCore

final class MenuBarAppearanceTests: XCTestCase {
  func testRoundTripPersistsBothProvidersIndependently() {
    let defaults = makeDefaults()
    var appearance = MenuBarAppearance(
      codex: MenuBarProviderSettings(mode: .icon, customLabel: "개발"),
      claude: MenuBarProviderSettings(mode: .text, customLabel: "업무"))

    appearance.save(to: defaults)
    XCTAssertEqual(MenuBarAppearance.load(from: defaults), appearance)

    appearance.setCustomLabel("Codex 별칭", for: .codex)
    appearance.save(to: defaults)
    let loaded = MenuBarAppearance.load(from: defaults)
    XCTAssertEqual(loaded.settings(for: .codex).customLabel, "Codex 별칭")
    XCTAssertEqual(loaded.settings(for: .codex).mode, .icon)
    XCTAssertEqual(loaded.settings(for: .claude).customLabel, "업무")
    XCTAssertEqual(loaded.settings(for: .claude).mode, .text)
  }

  func testInvalidModeFallsBackToTextWithoutAffectingOtherProvider() throws {
    let defaults = makeDefaults()
    let data = try JSONSerialization.data(
      withJSONObject: [
        "codex": ["mode": "unsupported", "customLabel": "Codex 별칭"],
        "claude": ["mode": "icon", "customLabel": "Claude 별칭"],
      ])
    defaults.set(data, forKey: MenuBarAppearance.userDefaultsKey)

    let appearance = MenuBarAppearance.load(from: defaults)

    XCTAssertEqual(appearance.settings(for: .codex).mode, .text)
    XCTAssertEqual(appearance.settings(for: .codex).customLabel, "Codex 별칭")
    XCTAssertEqual(appearance.settings(for: .claude).mode, .icon)
    XCTAssertEqual(appearance.settings(for: .claude).customLabel, "Claude 별칭")
  }

  func testLabelNormalizationHandlesBlankControlCharactersAndLength() {
    let blank = MenuBarProviderSettings(mode: .text, customLabel: " \t\n\r ")
    XCTAssertEqual(blank.customLabel, "")
    XCTAssertEqual(blank.displayLabel(for: .codex), "Codex")
    XCTAssertEqual(blank.displayLabel(for: .claude), "Claude")

    let controlCharacters = MenuBarProviderSettings(
      mode: .text, customLabel: "  Alpha\n\tBeta\r  ")
    XCTAssertEqual(controlCharacters.customLabel, "Alpha Beta")
    XCTAssertFalse(
      controlCharacters.customLabel.unicodeScalars.contains {
        CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
      })

    let longLabel = MenuBarProviderSettings(
      mode: .text, customLabel: String(repeating: "가", count: 100))
    XCTAssertEqual(longLabel.customLabel.count, MenuBarProviderSettings.maxLabelLength)
  }

  func testIconModeKeepsCustomLabelForWhenTextModeReturns() {
    var settings = MenuBarProviderSettings(mode: .text, customLabel: "내 Codex")
    settings.mode = .icon

    XCTAssertEqual(settings.customLabel, "내 Codex")
    XCTAssertEqual(settings.displayLabel(for: .codex), "내 Codex")

    settings.mode = .text
    XCTAssertEqual(settings.displayLabel(for: .codex), "내 Codex")
  }

  func testDefaultSelectsOnlyFirstUsageWindow() {
    let usage = ProviderUsage(
      provider: .claude,
      windows: [
        UsageWindow(id: "session", title: "세션", remainingPercent: 80, resetAt: nil),
        UsageWindow(id: "weekly", title: "주간", remainingPercent: 60, resetAt: nil),
      ])
    let settings = MenuBarProviderSettings()

    XCTAssertEqual(settings.selectedWindowIDs(for: usage), ["session"])
    XCTAssertEqual(settings.selectedWindows(for: usage).map(\.id), ["session"])
  }

  func testExplicitSelectionSupportsMultipleIDsAndDoesNotFallback() {
    let usage = ProviderUsage(
      provider: .codex,
      windows: [
        UsageWindow(id: "session", title: "세션", remainingPercent: 80, resetAt: nil),
        UsageWindow(id: "weekly", title: "주간", remainingPercent: 60, resetAt: nil),
      ])
    var settings = MenuBarProviderSettings(selectedWindowIDs: ["weekly", "missing"])

    XCTAssertEqual(settings.selectedWindows(for: usage).map(\.id), ["weekly"])

    settings.setSelectedWindowIDs(["weekly", "session"])
    XCTAssertEqual(settings.selectedWindows(for: usage).map(\.id), ["session", "weekly"])
    XCTAssertEqual(settings.selectedWindows(for: usage).map(\.remainingPercent), [80, 60])

    settings.setSelectedWindowIDs(["missing"])
    XCTAssertTrue(settings.selectedWindows(for: usage).isEmpty)

    settings.setSelectedWindowIDs([])
    XCTAssertTrue(settings.selectedWindows(for: usage).isEmpty)
    XCTAssertEqual(settings.selectedWindowIDs(for: usage), [])
  }

  func testWindowLabelModesAreIndependentAndNormalizeCustomLabels() {
    let window = UsageWindow(
      id: "fable",
      title: "Fable",
      remainingPercent: 42,
      resetAt: nil
    )
    var settings = MenuBarProviderSettings(selectedWindowIDs: ["fable"])

    settings.setWindowLabelMode(.hidden, for: window.id)
    XCTAssertNil(settings.displayLabel(for: window))

    settings.setWindowLabelMode(.title, for: window.id)
    XCTAssertEqual(settings.displayLabel(for: window), "Fable")

    settings.setWindowLabelMode(.custom, for: window.id)
    settings.setWindowCustomLabel("  Fable\n잔여  ", for: window.id)
    XCTAssertEqual(settings.displayLabel(for: window), "Fable 잔여")

    settings.setWindowCustomLabel(" \t\n ", for: window.id)
    XCTAssertNil(settings.displayLabel(for: window))
  }

  func testWindowSelectionAndLabelsPersistAcrossReload() {
    let defaults = makeDefaults()
    let appearance = MenuBarAppearance(
      codex: MenuBarProviderSettings(
        mode: .icon,
        customLabel: "Codex 별칭",
        selectedWindowIDs: ["session", "fable"],
        windowSettings: [
          "session": MenuBarWindowSettings(mode: .hidden),
          "fable": MenuBarWindowSettings(mode: .custom, customLabel: " Fable \n잔여 "),
        ]),
      claude: MenuBarProviderSettings(
        mode: .text,
        customLabel: "Claude 별칭",
        selectedWindowIDs: []))

    appearance.save(to: defaults)
    let loaded = MenuBarAppearance.load(from: defaults)

    XCTAssertEqual(loaded, appearance)
    XCTAssertEqual(loaded.codex.selectedWindowIDs, ["session", "fable"])
    XCTAssertEqual(loaded.codex.settings(for: "session").mode, .hidden)
    XCTAssertEqual(
      loaded.codex.settings(for: "fable").customLabel,
      "Fable 잔여"
    )
    XCTAssertEqual(loaded.claude.selectedWindowIDs, [])
    XCTAssertEqual(loaded.codex.displayLabel(for: .codex), "Codex 별칭")
    XCTAssertEqual(loaded.claude.displayLabel(for: .claude), "Claude 별칭")
  }

  func testMissingNewFieldsKeepExistingProviderSettings() throws {
    let defaults = makeDefaults()
    let data = try JSONSerialization.data(
      withJSONObject: [
        "codex": ["mode": "icon", "customLabel": "Codex 별칭"],
        "claude": ["mode": "text", "customLabel": "Claude 별칭"],
      ])
    defaults.set(data, forKey: MenuBarAppearance.userDefaultsKey)

    let appearance = MenuBarAppearance.load(from: defaults)

    XCTAssertNil(appearance.codex.selectedWindowIDs)
    XCTAssertTrue(appearance.codex.windowSettings.isEmpty)
    XCTAssertEqual(appearance.codex.displayLabel(for: .codex), "Codex 별칭")
    XCTAssertEqual(appearance.claude.displayLabel(for: .claude), "Claude 별칭")
  }

  private func makeDefaults() -> UserDefaults {
    let suiteName = "AgentMeter.MenuBarAppearanceTests.\(UUID().uuidString)"
    return UserDefaults(suiteName: suiteName)!
  }
}
