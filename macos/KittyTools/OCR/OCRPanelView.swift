// OCR 浮窗（和截图翻译弹出的翻译浮窗一模一样的三层结构，2026-11-17 用户要求）：顶栏 = 服务胶囊（全部服务 / 某一家）+
// 语言胶囊 + 图钉 + 「⋯」菜单；中间原文卡 = 框下来的截图（预览）+ 一行尺寸和字数 + 复制 / 重新识别 / 导出 / 清空；
// 下面每张卡一个服务的结果（标题行 = 服务图标 + 名字 + 行数和用时，正文可选中、最多 8 行，超出在卡片里滚）。
// 尺寸、圆角、按钮格子、材质都照 TranslatePanelView / ProviderCardView：两个浮窗摆在一起是同一套皮肤。
// 没有常驻的「识别」按钮：框选完就识别；改了语言或服务胶囊自动重跑，⌘R 也可以。

import AppKit
import SwiftUI

struct OCRPanelView: View {
  @Bindable var coordinator: OCRCoordinator
  /// 内容要的高度、至少要放得下的高度（浮窗按它伸缩，顶边不动）
  var resize: (_ height: CGFloat, _ mustFit: CGFloat) -> Void = { _, _ in }

  @AppStorage(Prefs.floatingPinned) private var pinned = false
  @State private var chromeHeight: CGFloat = 0
  @State private var resultsHeight: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 浮窗默认宽度（「恢复默认大小」回到它）
  static let defaultWidth: CGFloat = 420
  static let minHeight: CGFloat = 220

  var body: some View {
    VStack(spacing: 10) {
      VStack(spacing: 10) {
        header
        sourceArea
      }
      .padding(.horizontal, 12)
      .padding(.top, 12)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        chromeHeight = $0
      }
      results
        .frame(maxHeight: .infinity)
    }
    .padding(.bottom, 2)
    .onChange(of: [desiredHeight, mustFitHeight], initial: true) {
      resize(desiredHeight, mustFitHeight)
    }
  }

  /// 有结果卡片时按内容高度，空态 / 提示给固定的 240（同翻译浮窗空态的 200，这里多一行快捷键）
  private var desiredHeight: CGFloat {
    let body: CGFloat =
      coordinator.notice == nil && !coordinator.cards.isEmpty ? resultsHeight : 240
    return ceil(chromeHeight + 10 + body + 2)
  }

  private var mustFitHeight: CGFloat { desiredHeight }

  // MARK: 顶栏

  private var header: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        serviceMenu
        languageMenu
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 2) {
        Button {
          pinned.toggle()
        } label: {
          Image(systemName: pinned ? "pin.fill" : "pin")
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 24, height: 24)
            .contentShape(.rect)
        }
        .foregroundStyle(pinned ? Style.brand : .secondary)
        .help(pinned ? "已固定：点别处不收起（⌘P）" : "固定浮窗（⌘P）")
        .accessibilityLabel("固定浮窗")
        .accessibilityValue(pinned ? "已固定" : "未固定")
        moreMenu
      }
      .font(.system(size: 13, weight: .medium))
      .symbolRenderingMode(.hierarchical)
      .fixedSize()
    }
    .buttonStyle(.plain)
    .frame(height: 28)
  }

  /// 服务胶囊：全部服务 / 某一家（只列开着的）。选了就重新识别
  private var serviceMenu: some View {
    Menu {
      Picker(
        "OCR 服务",
        selection: Binding {
          coordinator.serviceChoice
        } set: { choice in
          coordinator.serviceChoice = choice
          coordinator.choiceChanged()
        }
      ) {
        Text("全部服务").tag("")
        Divider()
        ForEach(coordinator.services.enabled) { service in
          Text(service.name).tag(service.id)
        }
      }
      .pickerStyle(.inline)
    } label: {
      LanguageCapsule(title: serviceTitle, showsAutoTag: false)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help("OCR 服务")
    .accessibilityLabel("OCR 服务")
    .accessibilityValue(serviceTitle)
  }

  private var serviceTitle: String {
    if !coordinator.serviceChoice.isEmpty,
      let service = coordinator.services.enabled.first(where: { $0.id == coordinator.serviceChoice }
      )
    {
      return service.name
    }
    let enabled = coordinator.services.enabled
    return enabled.count > 1 ? "全部服务" : enabled.first?.name ?? "没有服务"
  }

  /// 语言胶囊：自动 / 指定一种（指定时各家按自己的语言码发）
  private var languageMenu: some View {
    Menu {
      Picker(
        "识别语言",
        selection: Binding {
          coordinator.language
        } set: { language in
          coordinator.language = language
          coordinator.choiceChanged()
        }
      ) {
        Text("自动").tag("")
        Divider()
        ForEach(Lang.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
      }
      .pickerStyle(.inline)
    } label: {
      LanguageCapsule(title: OCRLanguage.title(coordinator.language), showsAutoTag: false)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help("识别语言")
    .accessibilityLabel("识别语言")
    .accessibilityValue(OCRLanguage.title(coordinator.language))
  }

  /// 「⋯」：重新识别、复制、导出、设置（键位和 OCRCoordinator.handleKeyEquivalent 一致）
  private var moreMenu: some View {
    Menu {
      Button("重新识别", systemImage: "arrow.clockwise") { coordinator.restart() }
        .keyboardShortcut("r")
        .disabled(coordinator.image == nil)
      Button("复制识别结果", systemImage: "doc.on.doc") { coordinator.copyPrimary() }
        .disabled(coordinator.primaryText == nil)
      Button("导出…", systemImage: "square.and.arrow.down") { coordinator.export() }
        .keyboardShortcut("e")
        .disabled(coordinator.primaryText == nil)
      Divider()
      Button("设置…") { coordinator.openSettings(nil) }
        .keyboardShortcut(",")
    } label: {
      Image(systemName: "ellipsis")
        .padding(.trailing, -1.5)
        .frame(width: 24, height: 24, alignment: .trailing)
        .contentShape(.rect)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help("更多：重新识别、复制、导出、设置")
    .accessibilityLabel("更多")
  }

  // MARK: 原文卡（截图）

  private var sourceArea: some View {
    VStack(alignment: .leading, spacing: 6) {
      Group {
        if let image = coordinator.image {
          Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 132)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("框选的截图")
            .accessibilityLabel("框选的截图")
        } else {
          Text("框选后这里显示截下来的图")
            .font(.system(size: 15))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .padding(.leading, 5)
            .padding(.top, 6)
        }
      }
      if coordinator.image != nil {
        Text(infoLine)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5)
      }
      HStack(spacing: 12) {
        Group {
          Button("复制文字", systemImage: "doc.on.doc") {
            if !coordinator.copyPrimary() { NSSound.beep() }
          }
          .disabled(coordinator.primaryText == nil)
          Button("重新识别", systemImage: "arrow.clockwise") { coordinator.restart() }
            .disabled(coordinator.image == nil)
          Button("导出…", systemImage: "square.and.arrow.down") { coordinator.export() }
            .disabled(coordinator.primaryText == nil)
          Button("清空", systemImage: "xmark.circle") { coordinator.clear() }
            .disabled(coordinator.image == nil)
        }
        .foregroundStyle(.secondary)
        Spacer()
        if let text = coordinator.primaryText {
          Text("\(text.count) 字")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .font(.system(size: 13, weight: .medium))
      .symbolRenderingMode(.hierarchical)
      .frame(height: 24)
      .padding(.leading, 10)
      .padding(.trailing, 12)
    }
    .padding(.top, 8)
    .padding(.bottom, 8)
    .modifier(InputBox(isFocused: false))
  }

  private var infoLine: String {
    guard let image = coordinator.image else { return "" }
    let size = "\(image.width) × \(image.height)"
    let lines = coordinator.cards.compactMap { card -> Int? in
      if case .done(let result) = card.state { return result.lines }
      return nil
    }
    return lines.isEmpty ? size : size + " · \(lines.max() ?? 0) 行"
  }

  // MARK: 结果

  @ViewBuilder private var results: some View {
    if let notice = coordinator.notice {
      EmptyState(symbol: "exclamationmark.bubble", title: notice) {
        Button("打开 OCR 设置") { coordinator.openSettings(nil) }.buttonStyle(BrandButtonStyle())
      }
      .padding(TranslatePanelView.emptyStateInset)
    } else if coordinator.services.enabled.isEmpty {
      EmptyState(symbol: "text.viewfinder", title: "没有启用的 OCR 服务") {
        Button("打开 OCR 设置") { coordinator.openSettings(nil) }.buttonStyle(BrandButtonStyle())
      }
      .padding(TranslatePanelView.emptyStateInset)
    } else if coordinator.image == nil || coordinator.cards.isEmpty {
      EmptyState(symbol: "text.viewfinder", title: "框选要识别的文字") {
        VStack(spacing: 6) {
          ForEach([HotKeyAction.screenshotOCR, .recognizeText], id: \.self) { action in
            HStack {
              Text(action.title).foregroundStyle(.secondary)
              Spacer()
              if let hotKey = action.hotKey {
                KeyCap(hotKey.display)
              } else {
                Text("未设置").foregroundStyle(.tertiary)
              }
            }
            .font(.system(size: 12))
            .frame(width: 200)
          }
        }
      }
      .padding(TranslatePanelView.emptyStateInset)
    } else {
      ScrollView {
        VStack(spacing: 10) {
          ForEach(coordinator.cards) { card in
            OCRCardView(
              card: card,
              isCopied: coordinator.copiedCard == card.id,
              copyTick: coordinator.copiedCard == card.id ? coordinator.copyTick : 0
            ) {
              coordinator.retry(card.id)
            } onCopy: {
              coordinator.copy(card.id)
            } onToggleCollapse: {
              coordinator.toggleCollapse(card.id)
            } onOpenSettings: {
              coordinator.openSettings(card.service.id)
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          resultsHeight = $0
        }
      }
    }
  }
}

// MARK: 结果卡

/// 一个 OCR 服务的结果卡：和 ProviderCardView 同一套（标题行 18 pt 服务块 + 名字 12 semibold + 小字 11 tertiary，
/// 右边复制 / 重试 / 折叠；正文 15 pt、行距 3.5、可选中、最多 8 行，超出在卡里滚）。
private struct OCRCardView: View {
  let card: OCRCoordinator.Card
  let isCopied: Bool
  let copyTick: Int
  let onRetry: () -> Void
  let onCopy: () -> Void
  let onToggleCollapse: () -> Void
  let onOpenSettings: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var retries = 0

  static let bodyLines = 8
  static let bodyLineSpacing: CGFloat = 3.5
  static let sideInset: CGFloat = 12

  /// 正文一行的高度（同 ProviderCardView）
  static func bodyLineHeight(fontSize: CGFloat) -> CGFloat {
    let font = NSFont.systemFont(ofSize: fontSize)
    return font.ascender.rounded(.up) + (-font.descender).rounded(.up) + font.leading
  }

  static func bodyCap(fontSize: CGFloat) -> CGFloat {
    let lines = CGFloat(bodyLines)
    return lines * bodyLineHeight(fontSize: fontSize) + (lines - 1) * bodyLineSpacing
  }

  private var failure: TranslateError? {
    if case .failed(let error) = card.state { return error }
    return nil
  }

  private var isDone: Bool {
    if case .done = card.state { true } else { false }
  }

  private var isRunning: Bool {
    switch card.state {
    case .waiting, .running: true
    default: false
    }
  }

  private var subtitle: String {
    if case .done(let result) = card.state {
      let seconds = card.seconds.map { String(format: "%.1f s", $0) }
      return (["\(result.lines) 行"] + [seconds].compactMap { $0 }).joined(separator: " · ")
    }
    return card.service.kind.subtitle
  }

  private var failureTint: Color? {
    guard let failure else { return nil }
    return switch failure.kind {
    case .config: Color(nsColor: .systemOrange)
    case .network, .service: Color(nsColor: .systemRed)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(.horizontal, Self.sideInset)
      VStack(spacing: 0) {
        if !card.isCollapsed {
          content
            .padding(.top, 3)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
      }
      .clipped()
    }
    .padding(.top, 7)
    .padding(.bottom, card.isCollapsed ? 7 : 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .clipped()
    .cardSurface(tint: failureTint)
    .overlay {
      RoundedRectangle(cornerRadius: Style.Radius.card, style: .continuous)
        .fill(Style.brand)
        .keyframeAnimator(initialValue: 0.0, trigger: copyTick) { view, value in
          view.opacity(value)
        } keyframes: { _ in
          KeyframeTrack {
            LinearKeyframe(isCopied && !reduceMotion ? 0.12 : 0, duration: 0.15)
            LinearKeyframe(0, duration: 0.25)
          }
        }
        .allowsHitTesting(false)
    }
    .animation(Style.Motion.settle.animation(reduced: reduceMotion), value: card.isCollapsed)
  }

  private var header: some View {
    HStack(spacing: 8) {
      OCRServiceTile(service: card.service)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(card.service.name)
          .font(.system(size: 12, weight: .semibold))
          .opacity(0.85)
          .lineLimit(1)
        Text(subtitle)
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }
      Spacer(minLength: 6)
      CardActions {
        if let text = card.state.text, !text.isEmpty {
          Button("复制", systemImage: isCopied ? "checkmark" : "doc.on.doc", action: onCopy)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel("复制\(card.service.name)的文字")
        }
        Button("重新识别", systemImage: "arrow.clockwise") {
          retries += 1
          onRetry()
        }
        .symbolEffect(.rotate, value: retries)
        .accessibilityLabel("用\(card.service.name)重新识别")
        Button(
          card.isCollapsed ? "展开" : "收起",
          systemImage: "chevron.down", action: onToggleCollapse
        )
        .rotationEffect(.degrees(card.isCollapsed ? 0 : 180))
        .accessibilityLabel(card.isCollapsed ? "展开" : "收起")
      }
    }
    .frame(height: 18)
  }

  @ViewBuilder private var content: some View {
    switch card.state {
    case .waiting, .running:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("识别中…").font(.system(size: 13)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .frame(height: 38)
      .padding(.horizontal, Self.sideInset)
    case .done(let result):
      ScrollView {
        Text(result.text)
          .font(.system(size: 15))
          .lineSpacing(Self.bodyLineSpacing)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Self.sideInset)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: Self.bodyCap(fontSize: 15))
      .fixedSize(horizontal: false, vertical: true)
    case .failed(let failure):
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: failure.kind == .config ? "key.fill" : "exclamationmark.triangle.fill")
          .font(.system(size: 12))
          .foregroundStyle(failureTint ?? .secondary)
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 6) {
          Text(failure.message)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          if failure.kind == .config {
            Button("打开设置") { onOpenSettings() }
              .buttonStyle(BrandButtonStyle())
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Self.sideInset)
      .padding(.bottom, 6)
    }
  }
}

// MARK: 服务图标

/// 服务身份：18 pt 圆角方块。百度 / 腾讯 / 火山用 ServiceLogo 里的官方图，Apple 系统用苹果符号；
/// 和翻译卡的服务块同一个大小、同一个圆角（边长 × 0.225）
struct OCRServiceTile: View {
  let service: OCRService
  var size: CGFloat = 18

  var body: some View {
    ZStack {
      if let logo = service.kind.logo {
        Image(decorative: logo)
          .resizable()
          .scaledToFill()
      } else {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
          .fill(Color(nsColor: .labelColor).opacity(0.08))
          .overlay {
            Image(systemName: "apple.logo")
              .font(.system(size: size * 0.55))
              .foregroundStyle(.secondary)
          }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    .accessibilityHidden(true)
  }
}
