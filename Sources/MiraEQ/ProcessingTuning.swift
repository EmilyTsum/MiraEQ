import Foundation

public enum LatencyMode: String, CaseIterable {
    case standard
    case low
    case ultra

    public var targetMs: Float {
        switch self {
        case .standard: return 12
        case .low: return 5
        case .ultra: return 1
        }
    }
}

public struct ProcessingTuning: Equatable {
    public var latencyMode: LatencyMode
    public var latencyModeIsSet: Bool
    public var spatialEnabled: Bool
    public var spatialEnabledIsSet: Bool
    public var bassHarmonicsAmount: Float
    public var bassHarmonicsAmountIsSet: Bool
    public var bassHarmonicsCutoffHz: Float
    public var bassHarmonicsCutoffHzIsSet: Bool
    public var bassHarmonicsSpeakerCutoffHz: Float
    public var bassHarmonicsSpeakerCutoffHzIsSet: Bool
    public var lowEndGuardAmount: Float
    public var lowEndGuardAmountIsSet: Bool

    public static let `default` = ProcessingTuning(
        latencyMode: .low,
        latencyModeIsSet: false,
        spatialEnabled: true,
        spatialEnabledIsSet: false,
        bassHarmonicsAmount: 8,
        bassHarmonicsAmountIsSet: false,
        bassHarmonicsCutoffHz: 135,
        bassHarmonicsCutoffHzIsSet: false,
        bassHarmonicsSpeakerCutoffHz: 135,
        bassHarmonicsSpeakerCutoffHzIsSet: false,
        lowEndGuardAmount: 45,
        lowEndGuardAmountIsSet: false
    )

    public init(
        latencyMode: LatencyMode,
        latencyModeIsSet: Bool = false,
        spatialEnabled: Bool,
        spatialEnabledIsSet: Bool = false,
        bassHarmonicsAmount: Float,
        bassHarmonicsAmountIsSet: Bool = false,
        bassHarmonicsCutoffHz: Float,
        bassHarmonicsCutoffHzIsSet: Bool = false,
        bassHarmonicsSpeakerCutoffHz: Float,
        bassHarmonicsSpeakerCutoffHzIsSet: Bool = false,
        lowEndGuardAmount: Float,
        lowEndGuardAmountIsSet: Bool = false
    ) {
        self.latencyMode = latencyMode
        self.latencyModeIsSet = latencyModeIsSet
        self.spatialEnabled = spatialEnabled
        self.spatialEnabledIsSet = spatialEnabledIsSet
        self.bassHarmonicsAmount = bassHarmonicsAmount
        self.bassHarmonicsAmountIsSet = bassHarmonicsAmountIsSet
        self.bassHarmonicsCutoffHz = bassHarmonicsCutoffHz
        self.bassHarmonicsCutoffHzIsSet = bassHarmonicsCutoffHzIsSet
        self.bassHarmonicsSpeakerCutoffHz = bassHarmonicsSpeakerCutoffHz
        self.bassHarmonicsSpeakerCutoffHzIsSet = bassHarmonicsSpeakerCutoffHzIsSet
        self.lowEndGuardAmount = lowEndGuardAmount
        self.lowEndGuardAmountIsSet = lowEndGuardAmountIsSet
    }

    init(effects: EffectConfig) {
        let latencyMode = LatencyMode.allCases.min {
            abs($0.targetMs - effects.latency.targetMs) < abs($1.targetMs - effects.latency.targetMs)
        } ?? ProcessingTuning.default.latencyMode

        let spatialEnabledIsSet = effects.surround.spatialModelIsSet || effects.delay.isEnabled
        let spatialEnabled = effects.surround.width > 0.0001
            || effects.surround.rearAmount > 0.0001
            || effects.surround.reverbMix > 0.0001
            || effects.delay.isEnabled

        let bassHarmonicsIsSet = effects.bassHarmonics.isEnabled

        self.init(
            latencyMode: latencyMode,
            latencyModeIsSet: effects.latency.isSet,
            spatialEnabled: spatialEnabled,
            spatialEnabledIsSet: spatialEnabledIsSet,
            bassHarmonicsAmount: clampedTuningValue(effects.bassHarmonics.amount, min: 0, max: 20),
            bassHarmonicsAmountIsSet: bassHarmonicsIsSet,
            bassHarmonicsCutoffHz: clampedTuningValue(effects.bassHarmonics.cutoffHz, min: 50, max: 260),
            bassHarmonicsCutoffHzIsSet: bassHarmonicsIsSet,
            bassHarmonicsSpeakerCutoffHz: clampedTuningValue(effects.bassHarmonics.speakerCutoffHz, min: 40, max: 260),
            bassHarmonicsSpeakerCutoffHzIsSet: bassHarmonicsIsSet,
            lowEndGuardAmount: clampedTuningValue(effects.lowEndGuard.amountPercent, min: 0, max: 80),
            lowEndGuardAmountIsSet: effects.lowEndGuard.isSet
        )
    }
}

public extension EQConfig {
    func applying(processingTuning: ProcessingTuning, spatialTuning: SpatialTuning) -> EQConfig {
        var tuned = self

        // Latency: hidden tuning > base preset > default
        if processingTuning.latencyModeIsSet {
            tuned.effects.latency.targetMs = processingTuning.latencyMode.targetMs
            tuned.effects.latency.isSet = true
        } else if !tuned.effects.latency.isSet {
            tuned.effects.latency.targetMs = ProcessingTuning.default.latencyMode.targetMs
            tuned.effects.latency.isSet = true
        }

        // Bass harmonics amount: hidden tuning > base preset > off
        if processingTuning.bassHarmonicsAmountIsSet {
            tuned.effects.bassHarmonics.amount = processingTuning.bassHarmonicsAmount
        } else if !tuned.effects.bassHarmonics.isEnabled {
            tuned.effects.bassHarmonics.amount = 0
        }

        // Bass harmonics cutoff / speaker cutoff: hidden tuning > base preset > default
        if processingTuning.bassHarmonicsCutoffHzIsSet {
            tuned.effects.bassHarmonics.cutoffHz = processingTuning.bassHarmonicsCutoffHz
        }
        if processingTuning.bassHarmonicsSpeakerCutoffHzIsSet {
            tuned.effects.bassHarmonics.speakerCutoffHz = processingTuning.bassHarmonicsSpeakerCutoffHz
        }
        if !tuned.effects.bassHarmonics.isEnabled {
            if !processingTuning.bassHarmonicsCutoffHzIsSet {
                tuned.effects.bassHarmonics.cutoffHz = 135
            }
            if !processingTuning.bassHarmonicsSpeakerCutoffHzIsSet {
                tuned.effects.bassHarmonics.speakerCutoffHz = 135
            }
        }

        // Low-end guard: hidden tuning amount > base preset amount > off;
        // other guard parameters use base preset values or the hardcoded default set.
        if processingTuning.lowEndGuardAmountIsSet {
            tuned.effects.lowEndGuard.amountPercent = processingTuning.lowEndGuardAmount
            tuned.effects.lowEndGuard.isSet = true
        } else if !tuned.effects.lowEndGuard.isSet {
            tuned.effects.lowEndGuard.amountPercent = 0
            tuned.effects.lowEndGuard.thresholdDb = -18
            tuned.effects.lowEndGuard.cutoffHz = 180
            tuned.effects.lowEndGuard.ratio = 4
            tuned.effects.lowEndGuard.maxReductionDb = 4.5
        }

        // Spatial on/off defaults: only apply when the hidden file explicitly set it.
        if processingTuning.spatialEnabledIsSet {
            if processingTuning.spatialEnabled {
                tuned.preamp -= 6.5
                tuned.effects.delay.timeMs = 5
                tuned.effects.delay.feedback = 0
                tuned.effects.delay.mix = 4
                tuned.effects.surround.width = 30
                tuned.effects.surround.reverbMix = 7
                tuned.effects.surround.rearAmount = 56
                tuned.effects.surround.rearDelayMs = 4.2
                tuned.effects.surround.rearShadow = 58
            } else {
                tuned.effects.delay.timeMs = 0
                tuned.effects.delay.feedback = 0
                tuned.effects.delay.mix = 0
                tuned.effects.surround.width = 0
                tuned.effects.surround.reverbMix = 0
                tuned.effects.surround.rearAmount = 0
                tuned.effects.surround.rearDelayMs = 4.2
                tuned.effects.surround.rearShadow = 58
            }
        }

        // Apply distance/strength spatial constants.
        tuned.effects.surround.apply(spatialTuning: spatialTuning)

        return tuned
    }
}
