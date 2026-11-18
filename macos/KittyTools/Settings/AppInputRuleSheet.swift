// 应用输入法 › 添加应用。选择应用和输入法后一次保存整条规则。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppInputRuleSheet: View {
  let sources: [AppInputSource]
  let configured: Set<String>
  let add: (AppInputRule) -> Bool
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusingSearch: Bool
  @State private var apps: [LauncherItem]?
  @State private var query = ""
  @State private var selectedID: String?
  @State private var sourceID: String
  @State private var mode = AppInputRule.Mode.follow
  @State private var choosingFile = false
  @State private var error: String?

  /// 借用启动器的应用目录。预览时可传入固定的列表和选中项。
  init(
    sources: [AppInputSource], initialSource: String, configured: Set<String>,
    previewApps: [LauncherItem]? = nil, previewSelection: String? = nil,
    add: @escaping (AppInputRule) -> Bool
  ) {
    self.sources = sources
    self.configured = configured
    self.add = add
    _sourceID = State(initialValue: initialSource)
    _apps = State(initialValue: previewApps)
    _selectedID = State(initialValue: previewSelection)
  }

  /// 左侧筛选应用，右侧完成规则。取消时丢弃草稿。
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("添加应用规则").font(.headline)
      HStack(alignment: .top, spacing: 14) {
        appBrowser.frame(maxWidth: .infinity)
        Divider()
        ruleEditor.frame(width: 248)
      }
      actions
    }
    .padding(20)
    .frame(width: 640, height: 440)
    .task { await loadApps() }
    .fileImporter(
      isPresented: $choosingFile, allowedContentTypes: [.applicationBundle], onCompletion: importApp
    )
  }

  /// 搜索列表中显示应用图标和已有规则状态。
  private var appBrowser: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("搜索应用", text: $query, prompt: Text("按应用名称搜索"))
        .textFieldStyle(.roundedBorder).focused($focusingSearch)
      appList
      Button("浏览其他应用…", systemImage: "folder") { choosingFile = true }
    }
  }

  /// 筛选时保留真实应用选择，已有规则也可搜索到。
  private var matching: [LauncherItem] {
    let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return (apps ?? []).filter { app in
      key.isEmpty || app.title.localizedStandardContains(key)
        || LauncherMatch.score(key, item: app) > 0
        || app.appBundleID?.localizedStandardContains(key) == true
    }
  }

  /// 载入、空结果和列表共用一块区域，保证操作按钮位置稳定。
  private var appList: some View {
    Group {
      if apps == nil {
        ProgressView("正在读取应用…")
      } else if matching.isEmpty {
        ContentUnavailableView("没有匹配的应用", systemImage: "magnifyingglass")
      } else {
        List(matching, selection: $selectedID) { app in
          if let id = app.appBundleID { appRow(app, configured: configured.contains(id)).tag(id) }
        }
        .listStyle(.inset)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// 行尾提示应用已有规则，用户不必再尝试添加才能发现。
  private func appRow(_ app: LauncherItem, configured: Bool) -> some View {
    HStack(spacing: 8) {
      appIcon(app, size: 22)
      Text(app.title).lineLimit(1)
      Spacer()
      if configured { Text("已设置").foregroundStyle(.secondary).font(.subheadline) }
    }
    .accessibilityElement(children: .combine)
  }

  /// 根据选中应用显示规则草稿或说明。
  private var ruleEditor: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let app = selected {
        HStack(spacing: 8) {
          appIcon(app, size: 32)
          Text(app.title).font(.headline).lineLimit(2)
        }
        if let id = app.appBundleID, configured.contains(id) {
          Text("此应用已有专属规则，可在设置页直接修改。")
            .foregroundStyle(.secondary)
        } else {
          ruleFields
        }
      } else {
        ContentUnavailableView("选择一个应用", systemImage: "app.badge.plus")
      }
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
  }

  /// 选中的输入法支持内部切换时，才显示中英文选项。
  private var ruleFields: some View {
    Form {
      AppInputSourcePicker(title: "输入法", sources: sources, selection: $sourceID)
      if sources.contains(where: { $0.id == sourceID && $0.modeOwner != nil }) {
        AppInputModePicker(title: "中英文模式", selection: $mode)
      }
    }
    .formStyle(.columns)
  }

  /// 有可保存的应用时才允许确认。错误留在弹窗内，草稿不会丢。
  private var actions: some View {
    HStack {
      if let error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
      Spacer()
      Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
      Button("添加规则", action: save).buttonStyle(BrandButtonStyle())
        .keyboardShortcut(.defaultAction).disabled(!canSave)
    }
  }

  /// 用当前标识定位选中应用，即便筛选词已变动也显示该应用。
  private var selected: LauncherItem? {
    guard let selectedID else { return nil }
    return apps?.first { $0.appBundleID == selectedID }
  }

  /// 已有规则的应用应从设置页编辑。
  private var canSave: Bool {
    guard let id = selected?.appBundleID else { return false }
    return !configured.contains(id)
  }

  /// 使用系统 App 图标，找不到图标时用统一的占位符号。
  private func appIcon(_ app: LauncherItem, size: CGFloat) -> some View {
    Group {
      if let icon = LauncherIcons.icon(for: app.target) {
        Image(nsImage: icon).resizable().scaledToFit()
      } else {
        Image(systemName: "app").foregroundStyle(.secondary)
      }
    }
    .frame(width: size, height: size).accessibilityHidden(true)
  }

  /// 后台读取应用，按 bundle ID 去重后以名称排序。
  private func loadApps() async {
    guard apps == nil else { return }
    focusingSearch = true
    let catalog = await AppCatalog.scanInBackground()
    guard !Task.isCancelled else { return }
    var seen: Set<String> = []
    apps = ((apps ?? []) + catalog).filter { app in
      guard let id = app.appBundleID else { return false }
      return seen.insert(id).inserted
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  /// 从任意目录选的 App 也进入同一个草稿流程。
  private func importApp(_ result: Result<URL, any Error>) {
    guard let url = try? result.get(), let id = Bundle(url: url)?.bundleIdentifier else {
      error = "无法读取所选应用，请选择一个 .app 文件。"
      return
    }
    if apps?.contains(where: { $0.appBundleID == id }) != true {
      let name = FileManager.default.displayName(atPath: url.path)
      let item = LauncherItem(
        kind: .app, target: url.path, title: name, subtitle: "", appBundleID: id)
      apps = [item] + (apps ?? [])
    }
    query = ""
    error = nil
    selectedID = id
  }

  /// 从已选应用和草稿选项构造完整规则，并一次写回。
  private func save() {
    guard canSave, let app = selected, let id = app.appBundleID else { return }
    guard add(AppInputRule(id: id, name: app.title, sourceID: sourceID, mode: mode)) else {
      error = "未能添加规则。该应用可能已在另一版本中配置。"
      return
    }
    dismiss()
  }
}
