import AudioToolbox
import CoreMedia

enum AudioLevels {
  /// Computes a peak level in dBFS (0 dBFS is full-scale).
  /// Returns `nil` if the sample buffer doesn't contain readable PCM.
  static func peakDBFS(from sampleBuffer: CMSampleBuffer) -> Float? {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
    guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return nil }

    let eps: Float = 1e-9
    var peak: Float = 0

    var block: CMBlockBuffer?
    var sizeNeeded: Int = 0

    // Planar/non-interleaved audio can have >1 buffer; query required size first.
    let stSize = withUnsafeMutablePointer(to: &block) { blockPtr in
      CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: &sizeNeeded,
        bufferListOut: nil,
        bufferListSize: 0,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        blockBufferOut: blockPtr
      )
    }
    guard stSize == noErr, sizeNeeded > 0 else { return nil }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }

    let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    let st = withUnsafeMutablePointer(to: &block) { blockPtr in
      CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: &sizeNeeded,
        bufferListOut: ablPtr,
        bufferListSize: sizeNeeded,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: 0,
        blockBufferOut: blockPtr
      )
    }
    guard st == noErr else { return nil }
    guard ablPtr.pointee.mNumberBuffers >= 1 else { return nil }

    let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let bits = Int(asbd.mBitsPerChannel)

    func scanFloat(_ data: UnsafeMutableRawPointer, _ byteCount: Int) {
      let n = byteCount / MemoryLayout<Float>.size
      let p = data.bindMemory(to: Float.self, capacity: n)
      for i in 0..<n { peak = max(peak, abs(p[i])) }
    }

    func scanInt16(_ data: UnsafeMutableRawPointer, _ byteCount: Int) {
      let n = byteCount / MemoryLayout<Int16>.size
      let p = data.bindMemory(to: Int16.self, capacity: n)
      for i in 0..<n { peak = max(peak, abs(Float(p[i])) / 32768.0) }
    }

    func scanInt32(_ data: UnsafeMutableRawPointer, _ byteCount: Int) {
      let n = byteCount / MemoryLayout<Int32>.size
      let p = data.bindMemory(to: Int32.self, capacity: n)
      let denom = Float(Int64(1) << 31)
      for i in 0..<n { peak = max(peak, abs(Float(p[i])) / denom) }
    }

    // Handle interleaved and non-interleaved by scanning every buffer.
    let buffersPtr = UnsafeMutableAudioBufferListPointer(ablPtr)
    for b in buffersPtr {
      guard let data = b.mData, b.mDataByteSize > 0 else { continue }
      if isFloat {
        scanFloat(data, Int(b.mDataByteSize))
      } else if bits == 16 {
        scanInt16(data, Int(b.mDataByteSize))
      } else if bits == 32 {
        scanInt32(data, Int(b.mDataByteSize))
      } else {
        continue
      }
    }

    return 20.0 * log10(max(eps, peak))
  }
}
