import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

func displayLabel(_ display: SCDisplay) -> String {
  let logicalW = Int(display.width)
  let logicalH = Int(display.height)
  let displayID = CGDirectDisplayID(display.displayID)

  var extra: [String] = []
  if let mode = CGDisplayCopyDisplayMode(displayID) {
    if mode.pixelWidth > 0 && mode.pixelHeight > 0 {
      extra.append("\(mode.pixelWidth)x\(mode.pixelHeight)px")
    }
    if mode.refreshRate > 0 {
      extra.append(String(format: "%.0fHz", mode.refreshRate))
    }
  }

  let base = "Display \(display.displayID) - \(logicalW)x\(logicalH)pt"
  if extra.isEmpty { return base }
  return base + " (" + extra.joined(separator: ", ") + ")"
}

struct CaptureGeometry {
  let sourceRect: CGRect
  let pixelWidth: Int
  let pixelHeight: Int
  let pointPixelScale: Double
}

func computeCaptureGeometry(rect: CGRect, scale: Double, fallbackLogicalSize: (Int, Int)) -> CaptureGeometry {
  if rect.width <= 0 || rect.height <= 0 || scale <= 0 {
    let (lw, lh) = fallbackLogicalSize
    return CaptureGeometry(
      sourceRect: CGRect(x: 0, y: 0, width: CGFloat(lw), height: CGFloat(lh)),
      pixelWidth: lw,
      pixelHeight: lh,
      pointPixelScale: 1.0
    )
  }

  let w = max(2, Int((rect.width * scale).rounded(.toNearestOrAwayFromZero)))
  let h = max(2, Int((rect.height * scale).rounded(.toNearestOrAwayFromZero)))
  return CaptureGeometry(sourceRect: rect, pixelWidth: w, pixelHeight: h, pointPixelScale: scale)
}

func captureGeometry(filter: SCContentFilter, fallbackLogicalSize: (Int, Int)) -> CaptureGeometry {
  // On modern macOS, ScreenCaptureKit exposes the content rect in points and a point->pixel scale factor.
  let rect = filter.contentRect
  let scale = Double(filter.pointPixelScale)
  return computeCaptureGeometry(rect: rect, scale: scale, fallbackLogicalSize: fallbackLogicalSize)
}

func microphoneLabel(_ device: AVCaptureDevice) -> String {
  let fmt = device.activeFormat.formatDescription
  guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else {
    return device.localizedName
  }
  let sr = Int(asbd.mSampleRate.rounded())
  let ch = Int(asbd.mChannelsPerFrame)
  if sr > 0 || ch > 0 {
    return "\(device.localizedName) (\(sr)Hz, \(ch)ch)"
  }
  return device.localizedName
}

func cameraLabel(_ device: AVCaptureDevice) -> String {
  let fmt = device.activeFormat.formatDescription
  let dims = CMVideoFormatDescriptionGetDimensions(fmt)
  var extra: [String] = []
  if dims.width > 0 && dims.height > 0 {
    extra.append("\(dims.width)x\(dims.height)")
  }
  let ranges = device.activeFormat.videoSupportedFrameRateRanges
  if let r = ranges.first, r.maxFrameRate > 0 {
    extra.append(String(format: "%.0ffps", r.maxFrameRate))
  }
  if extra.isEmpty { return device.localizedName }
  return "\(device.localizedName) (" + extra.joined(separator: ", ") + ")"
}
