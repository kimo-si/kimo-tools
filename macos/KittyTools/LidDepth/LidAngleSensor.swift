// 改编自 Mac Duo（Copyright 2026 Makito，Apache-2.0）。出处与许可见 Resources/mac-duo-LICENSE.txt。
import Foundation
import IOKit
import IOKit.hid

/// Reads the lid hinge angle from the MacBook orientation sensor.
///
/// The sensor is an Apple HID device on usage page `0x20`, usage `0x8A`, that
/// macOS marks as built-in. No product ID is required, and an external display
/// with the same usage is left out. Two reports carry the angle, both through
/// `kIOHIDReportTypeFeature`:
///
/// - Report 1: 3 bytes `[0x01, lo, hi]`, whole degrees, 0...360.
/// - Report 7: 5 bytes `[0x07, b0, b1, b2, b3]`, little-endian hundredths of a
///   degree. Not every model declares it, so report 1 is the fallback.
///
/// The value refreshes about every 100 ms and needs no permission.
nonisolated final class LidAngleSensor {

  /// Which report the sensor answers with, decided once at open time.
  enum Resolution {
    /// Report 7, 0.01 degree steps.
    case hundredthsOfADegree
    /// Report 1, 1 degree steps.
    case wholeDegrees

    var reportID: Int {
      switch self {
      case .hundredthsOfADegree: return 7
      case .wholeDegrees: return 1
      }
    }

  }

  private(set) var resolution: Resolution?
  private var manager: IOHIDManager?
  private var device: IOHIDDevice?
  private var buffer = [UInt8](repeating: 0, count: 32)

  var isAvailable: Bool { device != nil && resolution != nil }

  // 打开并识别可用的内建机盖传感器。
  init() {
    open()
  }

  // 释放 HID 管理器和设备句柄。
  deinit {
    if let manager {
      IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
  }

  /// The current lid angle in degrees, or `nil` if the read failed.
  ///
  /// 0 means closed. A MacBook opens to roughly 130 degrees.
  func angle() -> Double? {
    guard let resolution else { return nil }
    guard let bytes = read(reportID: resolution.reportID) else { return nil }
    guard bytes.first == UInt8(resolution.reportID) else { return nil }

    let degrees: Double
    switch resolution {
    case .hundredthsOfADegree:
      guard bytes.count >= 5 else { return nil }
      let raw =
        UInt32(bytes[1])
        | UInt32(bytes[2]) << 8
        | UInt32(bytes[3]) << 16
        | UInt32(bytes[4]) << 24
      degrees = Double(raw) / 100
    case .wholeDegrees:
      guard bytes.count >= 3 else { return nil }
      degrees = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
    }

    return (0...360).contains(degrees) ? degrees : nil
  }

  // MARK: - Device

  // 查找系统标为内建的 Apple HID 传感器，优先使用精细读数。
  private func open() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [
      kIOHIDVendorIDKey: 0x05AC,
      kIOHIDDeviceUsagePageKey: 0x20,
      kIOHIDDeviceUsageKey: 0x8A,
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

    guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
      return
    }
    self.manager = manager

    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
    for candidate in devices {
      // An external display can carry the same usage and reads 0.
      guard
        (IOHIDDeviceGetProperty(candidate, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue
          == true
      else {
        continue
      }
      device = candidate
      for format in [Resolution.hundredthsOfADegree, .wholeDegrees] {
        resolution = format
        if angle() != nil { return }
      }
    }
    device = nil
    resolution = nil
  }

  // 读取一个 HID Feature Report，按设备返回的长度裁剪。
  private func read(reportID: Int) -> [UInt8]? {
    guard let device else { return nil }
    var length = buffer.count
    let status = buffer.withUnsafeMutableBufferPointer { bytes -> IOReturn in
      guard let address = bytes.baseAddress else { return kIOReturnBadArgument }
      return IOHIDDeviceGetReport(
        device, kIOHIDReportTypeFeature, CFIndex(reportID), address, &length)
    }
    guard status == kIOReturnSuccess, (0...buffer.count).contains(length) else { return nil }
    return Array(buffer.prefix(length))
  }
}
