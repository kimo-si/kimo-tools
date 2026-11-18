// 设置 › 应用输入法。编辑默认输入法和每个 App 的专属规则。

import AppKit
import SwiftUI

struct AppInputTab: View {
  var previewSources: [AppInputSource]? = nil
  @AppStorage(Prefs.appInputRules) private var rulesText = "[]"
  @AppStorage(Prefs.appInputDefaultSource) private var defaultSource = AppInputRule
    .keepCurrentSource
  @AppStorage(Prefs.appInputDefaultMode) private var storedDefaultMode = ""
  @AppStorage(Prefs.appInputPrefersChinese) private var legacyPrefersChinese = true
  @State private var sources: [AppInputSource] = []
  @State private var trusted = false
  @State private var adding = false

  /// 先配置所有应用的默认值，再处理有特殊需求的应用。
  var body: some View {
    Form {
      defaultSection.gated(by: .appInput)
      rulesSection.gated(by: .appInput)
      if !trusted { Section { permissionRow }.gated(by: .appInput) }
      PluginRemoveSection(plugin: .appInput)
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
    .onSettingsBecameKey(perform: refresh)
    .sheet(isPresented: $adding) {
      AppInputRuleSheet(
        sources: sources, initialSource: initialSource, configured: Set(rules.values.map(\.id)),
        add: add)
    }
  }

  /// 默认输入法仅用于未单独配置的应用，默认模式也供专属规则引用。
  private var defaultSection: some View {
    Section {
      AppInputSourcePicker(title: "默认输入法", sources: sources, selection: $defaultSource)
      AppInputModePicker(
        title: "默认中英文模式", choices: AppInputRule.Mode.defaultChoices, selection: defaultMode)
    } header: {
      Text("默认规则")
    } footer: {
      SectionFootnote("未单独配置的应用在切到前台时使用默认规则。默认模式也适用于选择了「跟随默认模式」的专属规则。")
    }
  }

  /// 将旧版中文开关作为过渡值，选择新模式后直接保存该模式。
  private var defaultMode: Binding<AppInputRule.Mode> {
    Binding {
      .defaultMode(stored: storedDefaultMode, legacyPrefersChinese: legacyPrefersChinese)
    } set: {
      storedDefaultMode = $0.rawValue
    }
  }

  /// 只切换系统输入源时无需辅助功能权限。
  private var permissionRow: some View {
    PermissionRow(
      title: "辅助功能", detail: "读取输入法的中英文状态并在需要时切换",
      symbol: "hand.raised.fill", color: Style.Family.keyboard, granted: trusted
    ) { Permissions.grant(.accessibility) }
  }

  /// 添加入口位于列表上方，规则很多时也容易找到。
  private var rulesSection: some View {
    Section {
      Button("添加应用…", systemImage: "plus") { adding = true }
      if rules.values.isEmpty {
        Text("暂无专属规则").foregroundStyle(.secondary)
      }
      ForEach(rules.values) { rule in ruleRow(rule) }
    } header: {
      Text("应用专属规则")
    } footer: {
      SectionFootnote("专属规则优先。选「不自动切换」可让该应用保留当前输入法。")
    }
  }

  /// 将应用名和两个可直接编辑的选项放在同一行。
  private func ruleRow(_ rule: AppInputRule) -> some View {
    LabeledContent {
      HStack(spacing: 8) {
        AppInputSourcePicker(
          title: "\(rule.name)的输入法", sources: sources, selection: binding(rule, \.sourceID)
        )
        .labelsHidden().frame(maxWidth: 150)
        if sources.contains(where: { $0.id == rule.sourceID && $0.modeOwner != nil }) {
          AppInputModePicker(title: "\(rule.name)的中英文模式", selection: binding(rule, \.mode))
            .labelsHidden()
        }
        Button("移除\(rule.name)的专属规则", systemImage: "minus.circle") { remove(rule) }
          .labelStyle(.iconOnly).buttonStyle(.borderless)
          .help("移除专属规则，恢复使用默认规则")
      }
    } label: {
      Text(rule.name).lineLimit(1).help(rule.name)
    }
  }

  /// 读取最近同步或保存的规则。
  private var rules: AppInputRules { AppInputRules(rulesText) }

  /// 添加时优先带入已选的默认输入法，否则使用系统当前可用的输入法。
  private var initialSource: String {
    if sources.contains(where: { $0.id == defaultSource }) { return defaultSource }
    if let current = AppInputSource.currentID(), sources.contains(where: { $0.id == current }) {
      return current
    }
    return sources.first?.id ?? AppInputRule.keepCurrentSource
  }

  /// 只更新被编辑的字段，保留规则最近同步到的其他配置。
  private func binding<Value>(
    _ rule: AppInputRule, _ field: WritableKeyPath<AppInputRule, Value>
  ) -> Binding<Value> {
    Binding {
      (rules.rule(for: rule.id) ?? rule)[keyPath: field]
    } set: { value in
      var current = rules
      guard var updated = current.rule(for: rule.id) else { return }
      updated[keyPath: field] = value
      current.save(updated)
      if let text = current.encoded() { rulesText = text }
    }
  }

  /// App、输入法和模式一起确认后，再写入专属规则。
  private func add(_ rule: AppInputRule) -> Bool {
    var current = rules
    guard current.rule(for: rule.id) == nil else { return false }
    current.save(rule)
    guard let text = current.encoded() else { return false }
    rulesText = text
    return true
  }

  /// 移除专属规则后，该应用下次激活时恢复使用默认规则。
  private func remove(_ rule: AppInputRule) {
    var current = rules
    current.remove(rule.id)
    if let text = current.encoded() { rulesText = text }
  }

  /// 返回设置窗口时读回系统已启用的输入法和权限状态。
  private func refresh() {
    sources = previewSources ?? AppInputSource.available()
    trusted = previewSources != nil || Permissions.isAccessibilityTrusted
  }
}

/// 输入法菜单保留暂时不可用的值，防止系统调整输入源后静默修改规则。
struct AppInputSourcePicker: View {
  let title: String
  let sources: [AppInputSource]
  @Binding var selection: String

  /// 列出系统输入源和保留当前输入法的选项。
  var body: some View {
    Picker(title, selection: $selection) {
      Text("不自动切换").tag(AppInputRule.keepCurrentSource)
      if !selection.isEmpty, !sources.contains(where: { $0.id == selection }) {
        Text("输入法不可用").tag(selection)
      }
      ForEach(sources) { source in Text(source.name).tag(source.id) }
    }
  }
}

/// 所有入口共用模式名称，只在专属规则中提供跟随默认选项。
struct AppInputModePicker: View {
  let title: String
  var choices = AppInputRule.Mode.allCases
  @Binding var selection: AppInputRule.Mode

  /// 列出当前规则支持的中英文选项。
  var body: some View {
    Picker(title, selection: $selection) {
      ForEach(choices, id: \.self) { mode in Text(mode.title).tag(mode) }
    }
  }
}
