// 设置 › 默认应用。读取和写入 macOS 的文件类型关联，偏好里只保存列表中的扩展名。

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DefaultAppsTab: View {
  var appliesTextPresetOnOpen = true
  /// 文档截图使用示例关联，不读取正在使用的默认应用。
  var previewRows: [DefaultFileType.Row]? = nil
  @AppStorage(Prefs.defaultAppExtensions) private var extensions = DefaultFileType.presetExtensions
  @AppStorage(Feature.defaultApps.prefsKey) private var enabled = Feature.defaultApps.defaultOn
  @AppStorage(Prefs.defaultAppWinCPresetHandled, store: DefaultFileType.sharedDefaults)
  private var presetHandled = false
  @State private var input = ""
  @State private var rows: [DefaultFileType.Row] = []
  @State private var winC: URL?
  @State private var applying = false
  @State private var error: String?

  var body: some View {
    Form {
      Section {
        textPresetRow
        addRow
      } footer: {
        SectionFootnote("macOS 按文件类型保存关联。例如 jpg 和 jpeg 同属一种文件类型，默认应用会一起更改。")
      }
      .gated(by: .defaultApps)
      Section("文件类型") {
        if rows.isEmpty {
          Text("添加一个文件扩展名，查看或更改它的默认应用。")
            .foregroundStyle(.secondary)
        }
        ForEach(rows) { row in associationRow(row) }
      }
      .gated(by: .defaultApps)
      PluginRemoveSection(plugin: .defaultApps)
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
    .onChange(of: extensions, refresh)
    .onChange(of: enabled, refresh)
    .onSettingsBecameKey(perform: refresh)
    .task(id: enabled) {
      guard enabled, previewRows == nil, appliesTextPresetOnOpen, !presetHandled else { return }
      await applyTextPreset()
    }
    .alert(
      "没能更改默认应用",
      isPresented: Binding(
        get: { error != nil }, set: { if !$0 { error = nil } }
      )
    ) {
      Button("好", role: .cancel) { error = nil }
    } message: {
      Text(error ?? "")
    }
  }

  /// 允许用户主动恢复预置文本类型与 WinC 的关联。
  private var textPresetRow: some View {
    LabeledContent {
      Button("设为 WinC") {
        Task { await applyTextPreset() }
      }
      .disabled(applying || winC == nil || DefaultFileType.presetTargets(in: types).isEmpty)
    } label: {
      Text("常见文本格式")
      Text(winC == nil ? "安装 WinC 后可以设为默认应用" : "将列表中的预置文本类型设为用 WinC 打开")
    }
  }

  /// 输入完整扩展名后添加一行；添加本身只读系统关联。
  private var addRow: some View {
    LabeledContent("添加扩展名") {
      HStack(spacing: 8) {
        TextField("", text: $input, prompt: Text("例如 .pdf"))
          .textFieldStyle(.roundedBorder)
          .frame(width: 140)
          .accessibilityLabel("文件扩展名")
          .onSubmit(add)
        Button("添加", action: add)
          .disabled(DefaultFileType(input) == nil)
      }
    }
  }

  /// 显示真正的系统默认应用，并列出已注册可打开该类型的应用。
  private func associationRow(_ row: DefaultFileType.Row) -> some View {
    LabeledContent {
      Menu {
        ForEach(row.candidates) { app in
          Button(app.name) { apply(app.url, to: row.fileType) }
            .disabled(app.url == row.current?.url)
        }
        Button("选择其他应用…") { choose(for: row.fileType) }
        Divider()
        Button("从列表移除") { remove(row.fileType) }
      } label: {
        Text(row.current?.name ?? "没有默认应用")
          .lineLimit(1)
      }
      .help("更改 .\(row.fileType.suffix) 的默认应用")
      .disabled(applying)
    } label: {
      Text(".\(row.fileType.suffix)")
      if let description = row.fileType.type.localizedDescription {
        Text(description)
      }
    }
  }

  /// 从系统重新读取各类型的默认应用，包含在其他应用中修改过的关联。
  private func refresh() {
    if let previewRows {
      rows = previewRows
      return
    }
    winC = NSWorkspace.shared.urlForApplication(withBundleIdentifier: DefaultFileType.winCBundleID)
    guard enabled else { return }
    rows = types.map(DefaultFileType.Row.init)
  }

  /// 解析当前列表中有效且去重的扩展名。
  private var types: [DefaultFileType] {
    DefaultFileType.list(extensions)
  }

  /// 添加关注的扩展名。
  private func add() {
    guard enabled, let type = DefaultFileType(input) else { return }
    if !types.contains(type) { save(types + [type]) }
    input = ""
  }

  /// 从关注列表移除后缀；默认应用仍由系统管理。
  private func remove(_ type: DefaultFileType) {
    guard enabled else { return }
    save(types.filter { $0 != type })
  }

  /// 写入列表，系统关联仅在用户明确选择应用时改变。
  private func save(_ items: [DefaultFileType]) {
    extensions = items.map(\.suffix).joined(separator: "\n")
  }

  /// 从应用程序目录选择一个实际的 App 路径，避免同一 bundle ID 的多个副本选错。
  private func choose(for type: DefaultFileType) {
    let panel = NSOpenPanel()
    panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
    panel.allowedContentTypes = [.applicationBundle]
    panel.prompt = "设为默认"
    let chosen: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      apply(url, to: type)
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: chosen)
    } else {
      panel.begin(completionHandler: chosen)
    }
  }

  /// 交给系统更改文件关联。系统可能询问确认，完成后读取实际生效的默认项。
  private func apply(_ url: URL, to type: DefaultFileType) {
    guard enabled, !applying, Bundle(url: url)?.bundleIdentifier != nil else { return }
    applying = true
    Task {
      defer {
        applying = false
        refresh()
      }
      do {
        try await NSWorkspace.shared.setDefaultApplication(at: url, toOpen: type.type)
      } catch {
        self.error = error.localizedDescription
      }
    }
  }

  /// 逐一应用仍在列表中的文本类型。同一 UTType 只设一次，关闭功能会停止后续写入。
  private func applyTextPreset() async {
    guard enabled, !applying,
      let app = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: DefaultFileType.winCBundleID)
    else { return }
    let targets = DefaultFileType.presetTargets(in: types)
    guard !targets.isEmpty else { return }
    applying = true
    defer {
      applying = false
      refresh()
    }
    var failed: [String] = []
    for target in targets {
      guard enabled, !Task.isCancelled else { return }
      do {
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: target.type) != app {
          try await workspace.setDefaultApplication(at: app, toOpen: target.type)
        }
      } catch {
        failed.append(".\(target.suffix)")
      }
    }
    presetHandled = true
    if !failed.isEmpty { error = "这些文件类型没能设为 WinC。\(failed.joined(separator: "、"))" }
  }
}

/// 后缀对应的系统文件类型；扩展名的别名可以指向相同的 UTType。
struct DefaultFileType: Equatable {
  static let winCBundleID = "com.deeix.winc"
  private static let textPreset = [
    "txt", "md", "markdown", "log", "json", "yaml", "yml", "toml", "ini", "xml",
  ]
  static let presetExtensions = textPreset.joined(separator: "\n")
  /// 系统关联对这两版一样，首次应用标记也由两版共用。
  static let sharedDefaults = UserDefaults(suiteName: "com.yy.kitty-tools.native.defaultApps")
  let suffix: String
  let type: UTType
  private static let suffixCharacters = CharacterSet.alphanumerics.union(.init(charactersIn: "-_+"))

  /// 接受带点或不带点的单个扩展名，并统一大小写。
  init?(_ input: String) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let suffix = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
    guard !suffix.isEmpty, suffix.unicodeScalars.allSatisfy(Self.suffixCharacters.contains),
      let type = UTType(filenameExtension: suffix)
    else { return nil }
    self.suffix = suffix
    self.type = type
  }

  /// 读取保存的列表时保持先后顺序并丢掉非法项。
  static func list(_ text: String) -> [Self] {
    var seen: Set<String> = []
    return text.split(whereSeparator: \.isNewline).compactMap { line in
      guard let entry = Self(String(line)), seen.insert(entry.suffix).inserted else { return nil }
      return entry
    }
  }

  /// 将预置后缀加入已有列表，保留用户原来的顺序并按后缀去重。
  static func addingPreset(to text: String) -> String {
    list(text + "\n" + presetExtensions).map(\.suffix).joined(separator: "\n")
  }

  /// 只选出用户仍关注的预置后缀，并把 .md/.markdown 等别名合为同一个类型。
  static func presetTargets(in list: [Self]) -> [Self] {
    var seen: Set<UTType> = []
    return list.filter { textPreset.contains($0.suffix) && seen.insert($0.type).inserted }
  }

  /// 使用 App 路径作为标识，保留系统返回的真实应用。
  struct Application: Identifiable {
    let url: URL
    var id: URL { url }
    var name: String { FileManager.default.displayName(atPath: url.path) }
  }

  /// 从系统取得一行的当前关联与候选项。
  struct Row: Identifiable {
    let fileType: DefaultFileType
    let current: Application?
    let candidates: [Application]
    var id: String { fileType.suffix }

    /// 默认项由 Launch Services 决定，和应用候选列表分别查询。
    init(_ fileType: DefaultFileType) {
      let workspace = NSWorkspace.shared
      self.init(
        fileType, current: workspace.urlForApplication(toOpen: fileType.type).map(Application.init),
        candidates: workspace.urlsForApplications(toOpen: fileType.type).map(Application.init))
    }

    /// 用指定应用构建一行，供生产查询和屏外示例共用。
    init(_ fileType: DefaultFileType, current: Application?, candidates: [Application]) {
      self.fileType = fileType
      self.current = current
      self.candidates = candidates
    }
  }
}
