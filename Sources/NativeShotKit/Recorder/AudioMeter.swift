import CoreMedia

public enum AudioMeter {
    /// Peak amplitude 0...1 of a Float32 PCM buffer (SCStream delivers system and microphone audio this way).
    public static func peak(_ sb: CMSampleBuffer) -> Float {
        var size = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return 0 }
        var peak: Float = 0
        // The buffer list points into `block`; without this the optimiser may release it after the last use above.
        withExtendedLifetime(block) {
            for buf in UnsafeMutableAudioBufferListPointer(list) {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<Int(buf.mDataByteSize) / MemoryLayout<Float>.size { peak = max(peak, abs(data[i])) }
            }
        }
        return min(peak, 1)
    }
}
