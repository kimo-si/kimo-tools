// 按 App 切换输入法与内部模式。模拟系统操作，测试时不改真实键盘输入源。

import Testing

@testable import KittyTools

struct AppInputTests {
  private static let sogou = "com.sogou.inputmethod.sogou.pinyin"

  /// 同一输入法的中英文规则按 App 分别保存，偏好往返后仍可解析。
  @Test func savesLanguageIndependentlyForEachApp() throws {
    var rules = AppInputRules("[]")
    rules.save(.init(id: "test.editor", name: "编辑器", sourceID: Self.sogou, mode: .english))
    rules.save(.init(id: "test.chat", name: "聊天", sourceID: Self.sogou, mode: .chinese))
    let encoded = try #require(rules.encoded())
    let restored = AppInputRules(encoded)
    #expect(restored.rule(for: "test.editor")?.mode.target() == .english)
    #expect(restored.rule(for: "test.chat")?.mode.target() == .chinese)
    #expect(AppInputRule.Mode.follow.target(defaultLanguage: .english) == .english)
    #expect(AppInputRule.Mode.follow.target() == nil)
    #expect(AppInputRule.Mode.unchanged.target(defaultLanguage: .chinese) == nil)
    #expect(!SettingsSync.localKeys.contains(Prefs.appInputRules))
    #expect(SettingsArchive.kinds[Prefs.appInputRules] != nil)
  }

  /// 默认规则覆盖未配置的 App，专属输入法、语言和退出自动切换都优先。
  @Test func resolvesDefaultAndPerAppOverrides() throws {
    var rules = AppInputRules("[]")
    rules.save(.init(id: "test.chat", name: "聊天", sourceID: Self.sogou, mode: .chinese))
    rules.save(.init(id: "test.editor", name: "编辑器", sourceID: "editor.ime"))
    rules.save(.init(id: "test.excluded", name: "例外", sourceID: AppInputRule.keepCurrentSource))
    let restored = AppInputRules(try #require(rules.encoded()))
    let fallback = AppInputDefaults(sourceID: Self.sogou, mode: .english)
    #expect(
      restored.target(for: "test.new", defaults: fallback)
        == .init(sourceID: Self.sogou, language: .english))
    #expect(
      restored.target(for: "test.chat", defaults: fallback)
        == .init(sourceID: Self.sogou, language: .chinese))
    #expect(
      restored.target(for: "test.editor", defaults: fallback)
        == .init(sourceID: "editor.ime", language: .english))
    #expect(restored.target(for: "test.excluded", defaults: fallback) == nil)
    #expect(restored.target(for: "test.new", defaults: AppInputDefaults()) == nil)
    #expect(restored.target(for: "test.editor", defaults: AppInputDefaults())?.language == .chinese)
  }

  /// 升级时继续使用旧偏好；用户选定默认模式后以新值为准，并纳入设置同步。
  @Test func defaultModeRetainsLegacyPreferenceUntilChanged() {
    #expect(AppInputRule.Mode.defaultMode(stored: "", legacyPrefersChinese: true) == .chinese)
    #expect(AppInputRule.Mode.defaultMode(stored: "", legacyPrefersChinese: false) == .unchanged)
    #expect(
      AppInputRule.Mode.defaultMode(stored: "english", legacyPrefersChinese: true) == .english)
    for key in [Prefs.appInputDefaultSource, Prefs.appInputDefaultMode] {
      #expect(SettingsArchive.kinds[key] != nil)
      #expect(!SettingsSync.localKeys.contains(key))
    }
  }

  /// 识别搜狗图标，忽略静态名字、标点状态和不确定的冲突。
  @Test func recognizesModeMarkers() {
    #expect(
      AppInputMode.language(from: ["搜狗拼音", "statusModeCn Dark", "statusModeSBC"]) == .chinese)
    #expect(AppInputMode.language(from: ["statusModeEnInput Light"]) == .english)
    #expect(AppInputMode.language(from: ["当前：中文"]) == .chinese)
    #expect(AppInputMode.language(from: ["切换为中文", "搜狗拼音"]) == nil)
    #expect(AppInputMode.language(from: ["statusModeEn Dark", "statusModeCn Dark"]) == nil)
  }

  /// 两个 App 的规则用同一输入源，仍可在中文与英文间双向切换。
  @Test func switchingBetweenAppsChangesInternalModeInBothDirections() async {
    let fixture = SystemFixture()
    let first = AppInputTarget(sourceID: Self.sogou, language: .english)
    let second = AppInputTarget(sourceID: Self.sogou, language: .chinese)
    await fixture.driver.run(first, frontmost: { true })
    #expect(fixture.reported == .english)
    await fixture.driver.run(second, frontmost: { true })
    #expect(fixture.reported == .chinese)
    #expect(fixture.selected == [Self.sogou])
    #expect(fixture.toggles == 2)
    await fixture.driver.run(second, frontmost: { true })
    #expect(fixture.toggles == 2)
  }

  /// 模式读不到不试按，密码输入和刚离开的 App 都不执行。
  @Test func guardsAgainstUnknownSecureOrStaleContext() async {
    let fixture = SystemFixture()
    let target = AppInputTarget(sourceID: Self.sogou, language: .english)
    fixture.reported = nil
    await fixture.driver.run(target, frontmost: { true })
    #expect(fixture.selected == [Self.sogou] && fixture.toggles == 0)

    fixture.active = true
    fixture.reported = .chinese
    fixture.onRead = { fixture.active = false }
    await fixture.driver.run(target, frontmost: { fixture.active })
    #expect(fixture.toggles == 0)

    fixture.current = nil
    fixture.secure = true
    await fixture.driver.run(target, frontmost: { true })
    #expect(fixture.selected == [Self.sogou] && fixture.toggles == 0)
  }

  private final class SystemFixture {
    var current: String?
    var reported: AppInputLanguage? = .chinese
    var secure = false
    var active = true
    var onRead: () -> Void = {}
    var selected: [String] = []
    var toggles = 0

    /// 模拟切换输入源和输入法私有状态的两套操作。
    var driver: AppInputSwitch {
      AppInputSwitch(
        currentSource: { self.current },
        source: { AppInputSource(id: $0, name: "搜狗拼音", modeOwner: "搜狗") },
        select: {
          self.selected.append($0)
          self.current = $0
        }, canSwitch: { !self.secure },
        readMode: { _ in
          self.onRead()
          return self.reported
        },
        toggleMode: {
          self.toggles += 1
          self.reported = self.reported == .chinese ? .english : .chinese
          return true
        }, wait: { _ in })
    }
  }
}
