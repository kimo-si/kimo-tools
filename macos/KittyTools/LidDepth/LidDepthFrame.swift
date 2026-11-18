// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。

import CoreVideo
import Metal

/// 持有 Core Video 纹理直到 GPU 完成，避免系统提前回收 IOSurface。
nonisolated final class LidDepthFrame: Sendable {
  // Core Video 的对象没有 Sendable 标注。以只读句柄传递唯一一份额外的 retain，
  // 渲染编排只在主线程借用其中的纹理，GPU 命令完成后由 deinit 归还 retain。
  private let retainedAddress: UInt

  // 样本队列在自己的纹理缓存上包装画面，不复制像素。
  init?(cache: CVMetalTextureCache, pixels: CVPixelBuffer) {
    var wrapped: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, cache, pixels, nil, .bgra8Unorm_srgb,
      CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &wrapped)
    guard status == kCVReturnSuccess, let wrapped else { return nil }
    retainedAddress = UInt(bitPattern: Unmanaged.passRetained(wrapped).toOpaque())
  }

  // 画面离开收件箱和 GPU 命令后，归还 Core Video 的引用。
  deinit { retainedOwner?.release() }

  private var retainedOwner: Unmanaged<CVMetalTexture>? {
    UnsafeRawPointer(bitPattern: retainedAddress).map(Unmanaged.fromOpaque)
  }

  // 借用纹理编码命令，持帧的调用方负责延长 GPU 读取期间的生命周期。
  func withTexture(_ encode: (MTLTexture) -> Void) {
    guard let owner = retainedOwner?.takeUnretainedValue(),
      let texture = CVMetalTextureGetTexture(owner)
    else { return }
    encode(texture)
  }
}
