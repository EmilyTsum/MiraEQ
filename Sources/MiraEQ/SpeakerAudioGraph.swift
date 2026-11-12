import AVFAudio
import AudioToolbox

/// The only playback graph: speaker DSP source -> exact-size EQ -> protection.
/// No delay, reverb, spatializer, bass compressor, or saturation units exist.
@MainActor
final class SpeakerAudioGraph {
    let engine = AVAudioEngine()
    let source: AVAudioSourceNode
    let equalizer: AVAudioUnitEQ
    let limiter: AVAudioUnitEffect

    init(format: AVAudioFormat, config: EQConfig, renderBlock: @escaping AVAudioSourceNodeRenderBlock) {
        source = AVAudioSourceNode(format: format, renderBlock: renderBlock)
        equalizer = AVAudioUnitEQ(numberOfBands: max(1, min(config.bands.count, 32)))
        limiter = Self.effect(kAudioUnitSubType_PeakLimiter)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.003, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.024, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        [source, equalizer, limiter].forEach { engine.attach($0) }
        engine.connect(source, to: equalizer, format: format)
        engine.connect(equalizer, to: limiter, format: format)
        engine.connect(limiter, to: engine.outputNode, format: format)
        apply(config)
    }

    func apply(_ config: EQConfig, mix: Float = 1) {
        equalizer.globalGain = config.preamp * mix
        for (index, node) in equalizer.bands.enumerated() {
            guard index < config.bands.count else { node.bypass = true; continue }
            let band = config.bands[index]
            node.filterType = band.filterType
            node.frequency = band.frequency
            node.bandwidth = band.bandwidth
            node.gain = band.gain * mix
            node.bypass = band.bypass
        }
    }

    var latencyMs: Double {
        [equalizer.audioUnit, limiter.audioUnit].reduce(0) { sum, unit in
            var latency: Float64 = 0
            var size = UInt32(MemoryLayout<Float64>.size)
            let status = AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size)
            return sum + (status == noErr ? latency * 1_000 : 0)
        }
    }

    private static func effect(_ subtype: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        ))
    }
}
