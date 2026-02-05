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

func captureGeometry(filter: SCContentFilter, fallbackLogicalSize: (Int, Int)) -> CaptureGeometry {
  // On modern macOS, ScreenCaptureKit exposes the content rect in points and a point->pixel scale factor.
  let rect = filter.contentRect
  let scale = Double(filter.pointPixelScale)

  let w = max(2, Int((rect.width * scale).rounded(.toNearestOrAwayFromZero)))
  let h = max(2, Int((rect.height * scale).rounded(.toNearestOrAwayFromZero)))

  // Defensive fallback if the filter returns zeros for some reason.
  if w <= 0 || h <= 0 {
    let (lw, lh) = fallbackLogicalSize
    return CaptureGeometry(
      sourceRect: CGRect(x: 0, y: 0, width: CGFloat(lw), height: CGFloat(lh)),
      pixelWidth: lw,
      pixelHeight: lh,
      pointPixelScale: 1.0
    )
  }

  return CaptureGeometry(sourceRect: rect, pixelWidth: w, pixelHeight: h, pointPixelScale: scale)
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

