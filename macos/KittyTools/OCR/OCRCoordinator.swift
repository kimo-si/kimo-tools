// OCR 会话（照 TranslateCoordinator 的形状，少一半）：截下来的图 → 按当前选的服务（或全部启用的服务）并行识别 →
// 每张卡一个结果；第一个识别成功的定成主结果（自动复制、⌘C、导出都认它）。
// 换语言、换服务、重新识别都重跑；新会话取消旧请求。识别结果不写历史（Bob 的 OCR 也没有历史，只有翻译有）。
// 卡片状态、复制的对勾在会话里；设置里的开关、密钥由 OCRServiceStore 管。

import AppKit
import Carbon.HIToolbox
import Observation
import UniformTypeIdentifiers

@Observable final class OCRCoordinator {
  enum CardState: Equatable {
    case waiting
    case running
    case done(OCRResult)
    case failed(TranslateError)

    var text: String? {
      switch self {
      case .done(let result): result.text
      default: nil
      }
    }
  }

  struct Card: Identifiable {
    var service: OCRService
    var state: CardState
    /// 用时（秒）：识别成功时记下，卡片标题旁边写「0.4 s」
    var seconds: Double?
    /// 收起：只留标题行
    var isCollapsed = false
    var id: String { service.id }
  }

  let services: OCRServiceStore
  /// 截下来的原图（预览、重新识别都用它）
  var image: CGImage?
  var cards: [Card] = []
  /// 「没有启用的服务」这类提示；nil = 正常
  private(set) var notice: String?
  /// 空串 = 全部启用的服务，否则只识别这一个（顶栏的服务胶囊）
  var serviceChoice: String {
    didSet { UserDefaults.standard.set(serviceChoice, forKey: Prefs.ocrService) }
  }
  /// 识别语言：空串 = 自动（顶栏的语言胶囊）
  var language: String {
    didSet { UserDefaults.standard.set(language, forKey: Prefs.ocrLanguage) }
  }
  /// 刚被复制的卡片；每复制一次 copyTick 加一（对勾重放）
  private(set) var copiedCard: String?
  private(set) var copyTick = 0
  /// 这次会话已经自动复制过（只复制一次；重试别的服务不再换剪贴板）
  private(set) var copiedPrimary = false

  @ObservationIgnored private var tasks: [String: (run: Int, task: Task<Void, Never>)] = [:]
  @ObservationIgnored private var runs = 0

  /// 打开设置 › OCR（「⋯」菜单、空状态）；错误卡带服务 id，直达那个服务的详情页
  @ObservationIgnored var openSettings: (_ service: String?) -> Void = { _ in }
  /// 把焦点还给面板（⌘R 后）
  @ObservationIgnored var isPanelKey: () -> Bool = { false }

  init(services: OCRServiceStore) {
    self.services = services
    serviceChoice = UserDefaults.standard.string(forKey: Prefs.ocrService) ?? ""
    language = UserDefaults.standard.string(forKey: Prefs.ocrLanguage) ?? ""
  }

  var isRunning: Bool {
    cards.contains {
      switch $0.state {
      case .waiting, .running: true
      default: false
      }
    }
  }

  /// 主结果：按列表顺序第一个识别成功的
  var primaryText: String? {
    cards.compactMap(\.state.text).first { !$0.isEmpty }
  }

  /// 选中的语言（nil = 自动）
  var selectedLanguage: Lang? { Lang(rawValue: language) }

  /// 这一轮要识别哪几个服务（纯逻辑：空 = 全部启用的；选了一个但删了/关了时回落到全部）
  var activeServices: [OCRService] {
    let enabled = services.enabled
    guard !serviceChoice.isEmpty else { return enabled }
    let chosen = enabled.filter { $0.id == serviceChoice }
    return chosen.isEmpty ? enabled : chosen
  }

  /// 框完选区的入口：放图、开跑、清掉上一轮
  func recognize(_ image: CGImage) {
    // 设置页可能刚改过语言 / 服务：每次开跑前按偏好校正一次（顶栏改的已经写进偏好了，这里读到的是同一个）
    if let stored = UserDefaults.standard.string(forKey: Prefs.ocrLanguage) { language = stored }
    if let stored = UserDefaults.standard.string(forKey: Prefs.ocrService) {
      serviceChoice = stored
    }
    cancel()
    self.image = image
    notice = nil
    copiedPrimary = false
    let active = activeServices
    guard !active.isEmpty else {
      cards = []
      notice = "没有启用的 OCR 服务"
      return
    }
    cards = active.map { Card(service: $0, state: .waiting) }
    for service in active { run(service) }
  }

  /// 重新识别（⌘R、卡片上的 ↻）：还用这张图
  func restart() {
    guard let image else { return }
    recognize(image)
  }

  /// 换了语言 / 服务胶囊：有图就重跑
  func choiceChanged() {
    guard image != nil else { return }
    restart()
  }

  /// 清空（面板上的 ✕）：收起这次的结果，等下一次框选
  func clear() {
    cancel()
    image = nil
    cards = []
    notice = nil
    copiedPrimary = false
    copiedCard = nil
  }

  func cancel() {
    for entry in tasks.values { entry.task.cancel() }
    tasks = [:]
    for index in cards.indices {
      switch cards[index].state {
      case .waiting, .running: cards[index].state = .failed(.interrupted)
      default: break
      }
    }
  }

  /// 重试 / 重新识别一张卡（用设置里现在的那一份服务配置）
  func retry(_ id: String) {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
    guard let service = services.enabled.first(where: { $0.id == id }) else {
      cards.remove(at: index)
      return
    }
    cards[index].service = service
    run(service)
  }

  private func run(_ service: OCRService) {
    tasks[service.id]?.task.cancel()
    guard let image else { return }
    let language = selectedLanguage
    update(service.id, .waiting, seconds: nil)
    runs += 1
    let run = runs
    let started = Date()
    let task = Task {
      let current = { !Task.isCancelled && self.tasks[service.id]?.run == run }
      do {
        let result = try await service.recognize(image, language: language)
        guard current() else { return }
        update(service.id, .done(result), seconds: Date.now.timeIntervalSince(started))
        settlePrimary()
      } catch {
        guard current(), !(error is CancellationError) else { return }
        let failure =
          error as? TranslateError
          ?? TranslateError(message: error.localizedDescription)
        update(service.id, .failed(failure), seconds: nil)
      }
    }
    tasks[service.id] = (run, task)
  }

  private func update(_ id: String, _ state: CardState, seconds: Double?) {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
    cards[index].state = state
    cards[index].seconds = seconds
  }

  /// 主结果出来时自动复制一次（设置 › OCR「识别后自动复制」；只一次，后面的服务出来不各复制一遍）
  private func settlePrimary() {
    guard !copiedPrimary, let text = primaryText, !text.isEmpty,
      UserDefaults.standard.bool(forKey: Prefs.ocrAutoCopy)
    else { return }
    copiedPrimary = true
    Paster.write(string: text, record: true)
    if isPanelKey() { Island.announce("已复制识别结果") }
    flashCopy(cards.first { $0.state.text == text }?.id)
  }

  /// ⌘1–9 / 卡片上的复制：复制这张卡的文字（同时记进剪贴板历史）
  @discardableResult
  func copy(_ id: String, announces: Bool = true) -> Bool {
    guard let text = cards.first(where: { $0.id == id })?.state.text, !text.isEmpty else {
      return false
    }
    Paster.write(string: text, record: true)
    if announces { Island.announce("已复制文字") }
    flashCopy(id)
    return true
  }

  /// ⌘C / 面板上的「复制」：复制主结果
  @discardableResult
  func copyPrimary() -> Bool {
    guard let card = cards.first(where: { $0.state.text == primaryText }) else { return false }
    return copy(card.id)
  }

  private func flashCopy(_ id: String?) {
    guard let id else { return }
    copiedCard = id
    copyTick += 1
    let tick = copyTick
    Task {
      try? await Task.sleep(for: Style.copiedHold)
      if copyTick == tick { copiedCard = nil }
    }
  }

  func toggleCollapse(_ id: String) {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
    cards[index].isCollapsed.toggle()
  }

  /// 导出主结果为 .txt（⌘E、「⋯」菜单）
  func export() {
    guard let text = primaryText, !text.isEmpty else {
      NSSound.beep()
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.fileName()
    // 浮窗不激活本 App：走 FilePanel（面板提到最前、关掉把前台还回去），同截图另存为和翻译历史导出
    FilePanel.begin(panel) { response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        Island.announce("已导出识别结果")
      } catch {
        Island.announce("导出失败：\(error.localizedDescription)")
      }
    }
  }

  /// 默认文件名：识别 2026-11-17 13.30.00.txt
  static func fileName(_ date: Date = .now) -> String {
    "识别 "
      + date.formatted(date: .numeric, time: .standard).replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: ".") + ".txt"
  }

  /// ⌘R 重新识别、⌘E 导出、⌘, 设置、⌘1–9 复制第 N 张卡。⌘C 不截（正文可以选中，交给输入框复制选区）；
  /// ⌘W 在 OverlayPanel。
  func handleKeyEquivalent(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard flags == .command else { return false }
    let code = Int(event.keyCode)
    switch code {
    case kVK_ANSI_R: restart()
    case kVK_ANSI_E: export()
    case kVK_ANSI_Comma: openSettings(nil)
    default:
      guard let digit = Self.digitKeys.firstIndex(of: code) else { return false }
      if !(cards.indices.contains(digit) && copy(cards[digit].id)) { NSSound.beep() }
    }
    return true
  }

  private static let digitKeys = [
    kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
    kVK_ANSI_9,
  ]
}
