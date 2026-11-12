import CoreAudio
import AudioToolbox
import Foundation
import Darwin

/// Capture-thread kernel. Uses only the published preallocated resources;
/// the control actor owns registration and teardown of this block.
let captureAudioBlock: AudioDeviceIOBlock = {
    _, inInputData, _, outOutputData, _ in
    rtReaderCount.wrappingIncrement(ordering: .acquiring)
    defer {
        clearOutputBuffers(outOutputData)
        rtReaderCount.wrappingDecrement(ordering: .releasing)
    }
    guard let resPtr = rtActiveResources.load(ordering: .acquiring) else { return }
    let ringBuf = resPtr.pointee.ringBuffer.takeUnretainedValue()
    rtIOCallbackCount.wrappingIncrement(ordering: .relaxed)

    let inBufList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    let expectedChannels = resPtr.pointee.channelCount
    guard expectedChannels > 0, inBufList.count > 0 else { return }

    let frames: Int
    let totalSamples: Int
    if inBufList.count == 1 {
        guard let data = inBufList[0].mData else { return }
        let availableSamples = Int(inBufList[0].mDataByteSize) / MemoryLayout<Float>.size
        totalSamples = availableSamples - (availableSamples % expectedChannels)
        guard totalSamples > 0 else { return }
        frames = totalSamples / expectedChannels
        let interleavedSource = data.assumingMemoryBound(to: Float.self)
        var peak: Float = 0
        for sampleIndex in 0..<totalSamples {
            peak = max(peak, fabsf(interleavedSource[sampleIndex]))
        }
        if peak > audibleSampleThreshold {
            rtLastAudibleHostTime.store(mach_absolute_time(), ordering: .relaxed)
            rtLastAudiblePeakBits.store(peak.bitPattern, ordering: .relaxed)
        }
        let dropped = ringBuf.write(interleavedSource, count: totalSamples)
        if dropped > 0 {
            rtDroppedSampleCount.wrappingIncrement(by: UInt64(dropped), ordering: .relaxed)
        }
        rtLastInputFrameCount.store(UInt64(frames), ordering: .relaxed)
        rtAvailableSamples.store(UInt64(max(ringBuf.availableToRead, 0)), ordering: .relaxed)

        return
    }

    let inputChannelsToCopy = min(expectedChannels, inBufList.count)
    var availableFrames = Int.max
    for c in 0..<inputChannelsToCopy {
        let samples = Int(inBufList[c].mDataByteSize) / MemoryLayout<Float>.size
        availableFrames = min(availableFrames, samples)
    }
    guard availableFrames != Int.max, availableFrames > 0 else { return }
    frames = availableFrames
    guard frames <= Int.max / expectedChannels else { return }
    totalSamples = frames * expectedChannels
    rtLastInputFrameCount.store(UInt64(frames), ordering: .relaxed)

    if let interleaveBuf = resPtr.pointee.ioInterleaveBuffer, resPtr.pointee.ioInterleaveCapacity >= totalSamples {
        var peak: Float = 0
        for f in 0..<frames {
            for c in 0..<expectedChannels {
                if c < inBufList.count, let src = inBufList[c].mData?.assumingMemoryBound(to: Float.self) {
                    let sample = src[f]
                    interleaveBuf[f * expectedChannels + c] = sample
                    peak = max(peak, fabsf(sample))
                } else {
                    interleaveBuf[f * expectedChannels + c] = 0.0
                }
            }
        }
        if peak > audibleSampleThreshold {
            rtLastAudibleHostTime.store(mach_absolute_time(), ordering: .relaxed)
            rtLastAudiblePeakBits.store(peak.bitPattern, ordering: .relaxed)
        }
        let dropped = ringBuf.write(interleaveBuf, count: totalSamples)
        if dropped > 0 {
            rtDroppedSampleCount.wrappingIncrement(by: UInt64(dropped), ordering: .relaxed)
        }
    }
    rtAvailableSamples.store(UInt64(max(ringBuf.availableToRead, 0)), ordering: .relaxed)

}
