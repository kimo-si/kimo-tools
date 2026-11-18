// 设置 › 合盖动效。填写效果参数、授权和预览，使用设置页统一的分组表单。

import SwiftUI

struct LidDepthTab: View {
  struct Status {
    var sensorAvailable: Bool
    var angle: Double? = nil
  }

  let readStatus: () -> Status
  let refreshAccess: () -> Bool
  let preview: () -> Void

  @AppStorage(Prefs.lidDepthEnabled) private var enabled = LidDepthOptions.defaultEnabled
  @AppStorage(Prefs.lidDepthLive) private var live = LidDepthOptions.defaultLive
  @AppStorage(Prefs.lidDepthTimeout) private var timeout = LidDepthOptions.defaultTimeout
  @State private var screenRecording = false

  var body: some View {
    let status = readStatus()
    Form {
      Section("效果") {
        statusRow(status)
        if status.sensorAvailable {
          Toggle("合盖时播放动效", isOn: $enabled)
          Toggle(isOn: $live) {
            Text("实时画面")
            Text("关闭后，保留动效开始时的画面")
          }
          .disabled(!enabled)
          LabeledContent("试用效果") {
            Button("预览", action: preview)
              .disabled(!enabled || !screenRecording)
          }
        }
      }
      .gated(by: .lidDepth)
      if status.sensorAvailable {
        permissionSection.gated(by: .lidDepth)
        effectSettings.disabled(!enabled).gated(by: .lidDepth)
        Section {
          LabeledContent("效果参数") {
            Button("恢复默认") { LidDepthOptions.reset() }
          }
        }
        .gated(by: .lidDepth)
      }
      PluginRemoveSection(plugin: .lidDepth)
    }
    .formStyle(.grouped)
    .onSettingsBecameKey { refreshPermission() }
    .onAppear { refreshPermission() }
  }

  // 角度实时更新；未检测到传感器时显示可用条件。
  private func statusRow(_ status: Status) -> some View {
    LabeledContent {
      if let angle = status.angle {
        Text("\(angle, format: .number.precision(.fractionLength(1)))°").monospacedDigit()
      }
    } label: {
      Text(status.sensorAvailable ? "机盖角度" : "未检测到兼容的机盖传感器")
      if !status.sensorAvailable { Text("需要带有机盖角度传感器的 MacBook") }
    }
  }

  private var permissionSection: some View {
    Section("权限") {
      PermissionRow(
        title: "屏幕录制", detail: "只在合盖和预览时取用内建屏幕画面，画面仅在内存里处理",
        symbol: HotKeyAction.screenRecord.symbol, color: Style.Family.screenshot,
        granted: screenRecording
      ) { Permissions.grant(.screenRecording) }
    }
  }

  private var effectSettings: some View {
    Group {
      Section("触发") {
        LidDepthSlider(.angle)
        LidDepthSlider(.span)
        Toggle(isOn: $timeout) {
          Text("角度静止后结束动效")
          Text("机盖停在同一角度约 2 秒后回到原画面")
        }
      }
      Section("模糊与亮度") {
        LidDepthSlider(.blur)
        LidDepthSlider(.blurSpread)
        LidDepthSlider(.dim)
        LidDepthSlider(.dimSpread)
      }
      Section("透视") {
        LidDepthSlider(.lean)
        LidDepthSlider(.perspective)
      }
    }
  }

  // 从系统设置返回后同步授权状态和运行时。
  private func refreshPermission() {
    screenRecording = refreshAccess()
  }
}

private struct LidDepthSlider: View {
  typealias Setting = LidDepthOptions.Setting
  let setting: Setting
  @AppStorage private var value: Double

  // 参数的存储和范围与运行时共用。
  init(_ setting: Setting) {
    self.setting = setting
    _value = AppStorage(wrappedValue: setting.defaultValue, setting.key)
  }

  var body: some View {
    LabeledContent {
      HStack {
        Slider(value: sliderValue, in: setting.range) { Text(title) }
          .labelsHidden()
          .frame(minWidth: 96, idealWidth: 144, maxWidth: 180)
          .accessibilityValue(readout)
        Text(readout)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .fixedSize()
          .frame(minWidth: 44, alignment: .trailing)
          .accessibilityHidden(true)
      }
    } label: {
      Text(title)
      Text(detail)
    }
  }

  private var title: String {
    switch setting {
    case .angle: "起效角度"
    case .span: "完全起效的角度差"
    case .blur: "最大模糊"
    case .blurSpread: "模糊扩散"
    case .dim: "最大暗度"
    case .dimSpread: "渐暗范围"
    case .lean: "画面后倾"
    case .perspective: "透视强度"
    }
  }

  private var detail: String {
    switch setting {
    case .angle: "合盖至此角度时开始动效"
    case .span: "起效后继续合盖多少度，模糊和渐暗达到最大"
    case .blur: "远离转轴一侧的模糊半径"
    case .blurSpread: "数值越高，靠近转轴的画面也越模糊"
    case .dim: "完全起效时，屏幕远端的暗度"
    case .dimSpread: "屏幕达到最大暗度前的过渡范围"
    case .lean: "每合上 1°，画面后倾的角度"
    case .perspective: "数值越高，画面远端收窄得越明显"
    }
  }

  // 连续滑轨避免为每个步长画一条刻度，保存时仍使用约定的精度。
  private var sliderValue: Binding<Double> {
    Binding(
      get: { setting.clamped(value) },
      set: { value = setting.clamped(($0 / step).rounded() * step) })
  }

  private var step: Double {
    switch setting {
    case .angle, .span, .blur: 1
    case .lean: 0.1
    default: 0.01
    }
  }

  private var readout: String {
    let shown = setting.clamped(value)
    let whole = shown.formatted(.number.precision(.fractionLength(0)))
    return switch setting {
    case .angle, .span: "\(whole)°"
    case .blur: "\(whole) pt"
    case .lean: "\(shown.formatted(.number.precision(.fractionLength(1))))×"
    default: shown.formatted(.percent.precision(.fractionLength(0)))
    }
  }
}
