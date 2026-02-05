import AVFoundation
import CoreGraphics

func requestScreenRecordingAccess() -> Bool {
  if CGPreflightScreenCaptureAccess() { return true }
  return CGRequestScreenCaptureAccess()
}

func requestMicrophoneAccess() async -> Bool {
  if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
  return await withCheckedContinuation { cont in
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      cont.resume(returning: granted)
    }
  }
}

