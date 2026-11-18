// 设置 › OCR（2026-11-17）：启用开关、识别语言、识别后自动复制、浮窗位置和大小，以及 OCR 服务列表
// （和 设置 › 翻译 的服务列表同一套：行 = 图标 / 名称 / 状态 / 开关，拖动排序；「+」加回删掉的内置服务，单击一行进详情页改密钥）。
// 四个内置服务：Apple 系统（本机、离线、不用密钥）、百度、腾讯、火山。页头画在自己的 NavigationStack 里，推进时一起换掉。

import SwiftUI

struct OCRTab: View {
  @Bindable var services: OCRServiceStore
  @AppStorage(Prefs.ocrLanguage) private var language = ""
  @AppStorage(Prefs.ocrAutoCopy) private var autoCopy = true
  @AppStorage(Prefs.ocrPanelPosition) private var panelPosition = "top"
  @Environment(SettingsNavigation.self) private var navigation
  @State private var selection: String?
  @State private var keysRevision = 0

  var body: some View {
    NavigationStack(path: Bindable(navigation).path) {
      VStack(spacing: 0) {
        PageHeader(page: .ocr)
        form
      }
      .navigationTitle(SettingsPage.ocr.title)
      .navigationDestination(for: String.self) { id in
        OCRServiceDetail(store: services, id: id)
      }
    }
    .onChange(of: navigation.path) { keysRevision += 1 }
  }

  private var form: some View {
    Form {
      Section { FeatureToggle(feature: .ocr, inPage: true) }
      Group {
        Section {
          Picker("语言", selection: $language) {
            Text("自动").tag("")
            Divider()
            ForEach(Lang.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
          }
          Toggle(isOn: $autoCopy) {
            Text("识别后自动复制")
            Text("主结果出来就放进剪贴板，直接 ⌘V 粘贴；后面的服务出来不重复覆盖")
          }
        } header: {
          Text("识别")
        } footer: {
          SectionFootnote(
            "「自动」时 Apple 系统在本机判断语种，百度、腾讯、火山交给服务自己认；指定语言后按各家的语言码发，适合混排里只认一种文字。"
          )
        }
        Section {
          Picker(selection: $panelPosition) {
            Text("屏幕上方").tag("top")
            Text("跟随鼠标").tag("mouse")
            Text("上次位置").tag("last")
          } label: {
            Text("浮窗位置")
            Text("框选完出现的位置：屏幕上方是鼠标所在屏幕的上方正中，跟随鼠标是选区旁边；输入翻译总在上次拖到的位置")
          }
          .pickerStyle(.segmented)
          PanelSizeRow(
            detail: "拖左右两边改宽度，拖下边改最高多高（内容少时照样变矮）",
            widthKey: Prefs.ocrPanelWidth, heightKey: Prefs.ocrPanelMaxHeight,
            defaultWidth: OCRPanelView.defaultWidth)
          LabeledContent {
            ShortcutsButton()
          } label: {
            Text("OCR 浮窗里的按键")
            Text("⌘R 重新识别，⌘E 导出，⌘1–9 复制第 1–9 个结果，⌘, 设置；正文可以选中复制")
          }
        } header: {
          Text("行为")
        }
      }
      .gated(by: .ocr)
      Section {
        serviceList
        ListEditBar(
          removeTitle: "删除所选的服务", canRemove: selection != nil, remove: removeSelected
        ) {
          addMenu
        }
      } header: {
        Text("OCR 服务")
      } footer: {
        SectionFootnote(
          "开着的服务都会识别（浮窗顶部可以只选一家）；排在最前、识别成功的那个结果自动复制、⌘C 和导出都用它。截图翻译跟随浮窗选定的服务；选「全部」时使用第一个启用的服务。原图翻译目前支持 Apple 系统和腾讯 OCR。点一行填密钥，删掉后可从「+」加回。"
        )
      }
      .gated(by: .ocr)
    }
    .formStyle(.grouped)
  }

  private var serviceList: some View {
    List(selection: OrderedList.selection($selection, open: open)) {
      ForEach($services.services) { $service in
        OCRServiceRow(
          service: $service, status: service.settingsStatus,
          open: { open(service.id) },
          move: { move(service.id, by: $0) }
        )
        .tag(service.id)
      }
      .onMove { services.services.move(fromOffsets: $0, toOffset: $1) }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .orderedListFrame(rows: services.services.count)
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first {
        Button("设置…") { open(id) }
        Divider()
        Button("上移") { move(id, by: -1) }.disabled(id == services.services.first?.id)
        Button("下移") { move(id, by: 1) }.disabled(id == services.services.last?.id)
        Divider()
        Button("删除", role: .destructive) { remove(id) }
      }
    } primaryAction: { ids in
      if let id = ids.first { open(id) }
    }
    .onDeleteCommand(perform: removeSelected)
    // 从详情页回来时重建一次：行的状态读钥匙串，改了密钥不会让列表自己重画
    .id(keysRevision)
  }

  private var addMenu: some View {
    Menu {
      if services.missingBuiltins.isEmpty {
        Button("都添加了") {}.disabled(true)
      } else {
        ForEach(services.missingBuiltins, id: \.self) { kind in
          Button {
            add(kind)
          } label: {
            Label {
              Text(kind.defaultName)
            } icon: {
              OCRServiceTile(service: .builtin(kind), size: 18)
            }
          }
        }
      }
    } label: {
      Image(systemName: "plus")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .accessibilityLabel("添加 OCR 服务")
    .help("添加 OCR 服务")
  }

  private func add(_ kind: OCRService.Kind) {
    var service = OCRService.builtin(kind)
    service.isEnabled = true
    services.services.append(service)
    open(service.id)
  }

  private func open(_ id: String) {
    selection = nil
    navigation.path = [id]
  }

  private func remove(_ id: String) {
    services.remove(id)
    if selection == id { selection = nil }
  }

  private func removeSelected() {
    if let selection { remove(selection) }
  }

  private func move(_ id: String, by offset: Int) {
    guard let index = services.services.firstIndex(where: { $0.id == id }),
      services.services.indices.contains(index + offset)
    else { return }
    services.services.swapAt(index, index + offset)
  }
}

/// 服务行：图标、名称 + 状态、启用开关、›（和翻译服务列表同一套排版）
private struct OCRServiceRow: View {
  @Binding var service: OCRService
  let status: (text: String, isProblem: Bool)
  let open: () -> Void
  let move: (Int) -> Void

  var body: some View {
    HStack(spacing: 10) {
      OCRServiceTile(service: service, size: 24)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(service.name).font(.system(size: 13))
          if service.kind.isFree { OCRFreeTag() }
        }
        Text(status.text)
          .font(.system(size: 11))
          .foregroundStyle(OrderedList.statusStyle(isProblem: status.isProblem))
      }
      .lineLimit(1)
      .truncationMode(.tail)
      .accessibilityElement(children: .combine)
      Spacer(minLength: 8)
      Toggle("启用「\(service.name)」", isOn: $service.isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
      Image(systemName: "chevron.forward")
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .frame(height: OrderedList.rowHeight - 8)
    .accessibilityAction(named: "设置", open)
    .accessibilityAction(named: "上移") { move(-1) }
    .accessibilityAction(named: "下移") { move(1) }
  }
}

/// 名字后面的「免费」（同翻译服务列表的标签）
private struct OCRFreeTag: View {
  var body: some View {
    Text("免费")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(Style.brandInk)
      .padding(.horizontal, 4)
      .padding(.vertical, 1)
      .background(Style.brand.opacity(0.16), in: .capsule)
      .fixedSize()
  }
}

// MARK: 详情页

struct OCRServiceDetail: View {
  @Bindable var store: OCRServiceStore
  let id: String
  @Environment(\.dismiss) private var dismiss
  @State private var secrets: [String: String] = [:]
  @State private var result: (ok: Bool, text: String)?
  @State private var isBusy = false
  @FocusState private var focusedSecret: String?

  var body: some View {
    if let current = store.services.first(where: { $0.id == id }) {
      VStack(spacing: 0) {
        DetailHeader(
          title: current.name, status: current.settingsStatus.text,
          isProblem: current.settingsStatus.isProblem
        ) {
          OCRServiceTile(service: current, size: 40)
        }
        fields(current)
      }
      .navigationTitle(current.name)
      .toolbar { SettingsBackButton { dismiss() } }
      .task(id: id) {
        secrets = Dictionary(
          uniqueKeysWithValues: current.secretFields.map {
            ($0.name, current.secret($0.name) ?? "")
          })
      }
    }
  }

  private func fields(_ current: OCRService) -> some View {
    let service = binding(current)
    return Form {
      Section {
        Toggle("启用", isOn: service.isEnabled)
        if current.kind == .tencent {
          TextField(
            "地域", text: Binding(service.region, default: ""),
            prompt: Text("留空按 ap-beijing；开通的是别的地域时填上"))
        }
      } footer: {
        if current.kind == .apple {
          SectionFootnote("在本机用系统的文字识别，图片不上传、不用密钥、不花钱。")
        }
      }
      if !current.secretFields.isEmpty {
        Section {
          ForEach(current.secretFields, id: \.name) { field in
            SecureField(field.label, text: secretBinding(field.name), prompt: Text(field.prompt))
              .focused($focusedSecret, equals: field.name)
          }
        } header: {
          Text("密钥")
        } footer: {
          SectionFootnote("只存在这台 Mac 的钥匙串里。要先去服务商控制台开通对应的文字识别，再新建一个应用拿密钥。")
        }
      }
      Section {
        HStack(spacing: 8) {
          Button("测试连接", action: test).disabled(isBusy)
          if isBusy { ProgressView().controlSize(.small) }
          if let result {
            Label {
              Text(result.text).foregroundStyle(.secondary).lineLimit(2)
            } icon: {
              Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(Color(nsColor: result.ok ? .systemGreen : .systemRed))
            }
            .font(.caption)
          }
          Spacer(minLength: 0)
        }
      } footer: {
        SectionFootnote("用一张写着「Hello, world」的图识别一次。")
      }
    }
    .formStyle(.grouped)
  }

  private func binding(_ fallback: OCRService) -> Binding<OCRService> {
    Binding {
      store.services.first { $0.id == id } ?? fallback
    } set: { value in
      if let index = store.services.firstIndex(where: { $0.id == id }) {
        store.services[index] = value
      }
    }
  }

  private func secretBinding(_ field: String) -> Binding<String> {
    Binding {
      secrets[field] ?? ""
    } set: { value in
      secrets[field] = value
      store.services.first { $0.id == id }?
        .setSecret(value.trimmingCharacters(in: .whitespacesAndNewlines), field)
    }
  }

  /// 用一张合成图识别一次；成功时把启用打开（配好了就能用）
  private func test() {
    guard let service = store.services.first(where: { $0.id == id }),
      let image = OCRTestImage.make()
    else { return }
    isBusy = true
    result = nil
    Task {
      defer { isBusy = false }
      do {
        let recognized = try await service.recognize(image, language: nil)
        result = (true, recognized.text)
        if let index = store.services.firstIndex(where: { $0.id == id }),
          !store.services[index].isEnabled
        {
          store.services[index].isEnabled = true
        }
      } catch {
        result = (false, error.localizedDescription)
      }
    }
  }
}
