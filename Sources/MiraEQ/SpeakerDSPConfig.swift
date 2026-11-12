import Foundation

/// Immutable render configuration for the dedicated speaker chain. Coefficients
/// are calculated on the control thread, never in the per-frame processing loop.
struct DSPConfig {
    let bassHarmonicsAmount: Float
    let bassHarmonicsCutoffHz: Float
    let bassHarmonicsSpeakerCutoffHz: Float
    let bassHarmonicsLowpass: BiquadCoefficients
    let bassHarmonicsBandpass: BiquadCoefficients
    let bassHarmonicsDCPole: Float
    let bassHarmonicsEnvelopeAttack: Float
    let bassHarmonicsEnvelopeRelease: Float
    let bassFocusAmount: Float
    let bassFocusThresholdDb: Float
    let bassFocusMaxHighCutDb: Float
    let bassFocusMaxHighCutGain: Float
    let bassFocusAlpha: Float
    let lowEndGuardAmount: Float
    let lowEndGuardThresholdDb: Float
    let lowEndGuardThresholdLinear: Float
    let lowEndGuardCutoffHz: Float
    let lowEndGuardRatio: Float
    let lowEndGuardMaxReductionDb: Float
    let lowEndGuardMaxReductionGain: Float
    let lowEndGuardAlpha: Float
    let sampleRate: Float
    let maxRealtimeLatencySeconds: Float
    let loudnessAmount: Float
    let loudnessAlpha: Float

    init(effects: EffectConfig = EffectConfig(), sampleRate: Float = 48_000) {
        let rate = finiteClamped(sampleRate, default: 48_000, min: 8_000, max: 768_000)
        self.sampleRate = rate
        bassHarmonicsAmount = finiteClamped(effects.bassHarmonics.amount, default: 0, min: 0, max: 20)
        bassHarmonicsCutoffHz = finiteClamped(effects.bassHarmonics.cutoffHz, default: 135, min: 50, max: 260)
        let cutoff = finiteClamped(effects.bassHarmonics.speakerCutoffHz, default: 135, min: 40, max: 260)
        bassHarmonicsSpeakerCutoffHz = cutoff
        bassHarmonicsLowpass = lowpassBiquad(sampleRate: rate, cutoff: cutoff, q: 0.707)
        bassHarmonicsBandpass = bandpassBiquad(sampleRate: rate, center: min(max(cutoff * 2.828, 90), rate * 0.42), q: 1.414)
        bassHarmonicsDCPole = expf(-2 * Float.pi * 20 / rate)
        bassHarmonicsEnvelopeAttack = 1 - expf(-1 / (rate * 0.005))
        bassHarmonicsEnvelopeRelease = 1 - expf(-1 / (rate * 0.080))
        bassFocusAmount = finiteClamped(effects.bassFocus.amountPercent, default: 0, min: 0, max: 100)
        bassFocusThresholdDb = finiteClamped(effects.bassFocus.thresholdDb, default: -18, min: -40, max: -6)
        bassFocusMaxHighCutDb = finiteClamped(effects.bassFocus.maxHighCutDb, default: 7, min: 1, max: 12)
        bassFocusMaxHighCutGain = linearGain(forReductionDb: bassFocusAmount / 100 * min(max(bassFocusMaxHighCutDb, 1), 12))
        bassFocusAlpha = Self.alpha(cutoff: 2_650 - bassFocusAmount / 100 * 950, rate: rate, minimum: 0.02, maximum: 0.45)
        lowEndGuardAmount = finiteClamped(effects.lowEndGuard.amountPercent, default: 0, min: 0, max: 80)
        lowEndGuardThresholdDb = finiteClamped(effects.lowEndGuard.thresholdDb, default: -18, min: -36, max: -6)
        lowEndGuardThresholdLinear = linearGain(forReductionDb: -min(max(lowEndGuardThresholdDb, -36), -6))
        lowEndGuardCutoffHz = finiteClamped(effects.lowEndGuard.cutoffHz, default: 180, min: 90, max: 260)
        lowEndGuardRatio = finiteClamped(effects.lowEndGuard.ratio, default: 4, min: 1.5, max: 12)
        lowEndGuardMaxReductionDb = finiteClamped(effects.lowEndGuard.maxReductionDb, default: 5, min: 1, max: 10)
        lowEndGuardMaxReductionGain = linearGain(forReductionDb: min(max(lowEndGuardMaxReductionDb, 1), 10))
        lowEndGuardAlpha = Self.alpha(cutoff: min(max(lowEndGuardCutoffHz, 90), 260), rate: rate)
        maxRealtimeLatencySeconds = finiteClamped(effects.latency.targetMs, default: 1, min: 0.5, max: 80) / 1_000
        loudnessAmount = finiteClamped(effects.loudness.amount, default: 0, min: 0, max: 100)
        loudnessAlpha = Self.alpha(cutoff: 180, rate: rate)
    }

    private static func alpha(cutoff: Float, rate: Float, minimum: Float = 0.003, maximum: Float = 0.12) -> Float {
        min(max((2 * Float.pi * cutoff) / (2 * Float.pi * cutoff + rate), minimum), maximum)
    }
}

/// One graph and one processing order. Legacy preset tokens may still be read,
/// but unsupported effects cannot allocate resources or enter this signal path.
enum SpeakerEngineProfile {
    static let presetName = "M5_MacBook_Air_Rich.txt"
    static let stages = ["Loudness", "Bass Harmonics", "Bass Focus", "Low End Guard", "EQ", "Peak Limiter"]

    static func prepare(_ input: EQConfig) -> EQConfig {
        var config = input
        config.preamp = 0
        config.bands = input.bands.prefix(32).map { input in
            var band = input
            band.frequency = finiteClamped(input.frequency, default: 1_000, min: 20, max: 20_000)
            band.bandwidth = finiteClamped(input.bandwidth, default: 1, min: 0.05, max: 5)
            band.gain = finiteClamped(input.gain, default: 0, min: -96, max: 24)
            return band
        }
        config.effects.delay = DelayEffectConfig()
        config.effects.surround = SurroundEffectConfig()
        config.effects.bassMono = BassMonoEffectConfig()
        config.effects.bassComp = BassCompEffectConfig()
        config.effects.softLimit = SoftLimitEffectConfig()
        return config
    }
}
