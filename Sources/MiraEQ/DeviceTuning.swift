import Foundation

public enum LatencyMode: String, CaseIterable {
    case standard, low, ultra

    public var targetMs: Float {
        switch self {
        case .standard: return 12
        case .low: return 5
        case .ultra: return 1
        }
    }
}

/// Per-device overrides. `nil` inherits the EQ preset; zero explicitly turns
/// an effect off. The same composition and serialization serve the app and CLI.
struct DeviceTuning: Equatable {
    var latencyTargetMs: Float?
    var spatialEnabled: Bool?
    var listenerDistanceCm: Float?
    var spatialStrengthPercent: Float?
    var bassHarmonicsAmount: Float?
    var bassHarmonicsCutoffHz: Float?
    var bassHarmonicsSpeakerCutoffHz: Float?
    var lowEndGuardAmount: Float?
    var bassFocusAmount: Float?
    var bassCompAmount: Float?
    var bassCompCrossoverHz: Float?
    var softLimitDrive: Float?

    func applying(to base: EQConfig) -> EQConfig {
        var config = base
        if let latencyTargetMs {
            config.effects.latency = LatencyEffectConfig(targetMs: latencyTargetMs, isSet: true)
        } else if !config.effects.latency.isSet {
            config.effects.latency = LatencyEffectConfig(targetMs: LatencyMode.ultra.targetMs, isSet: true)
        }

        if let bassHarmonicsAmount { config.effects.bassHarmonics.amount = bassHarmonicsAmount }
        if let bassHarmonicsCutoffHz { config.effects.bassHarmonics.cutoffHz = bassHarmonicsCutoffHz }
        if let bassHarmonicsSpeakerCutoffHz { config.effects.bassHarmonics.speakerCutoffHz = bassHarmonicsSpeakerCutoffHz }
        if !config.effects.bassHarmonics.isEnabled {
            config.effects.bassHarmonics.cutoffHz = bassHarmonicsCutoffHz ?? 135
            config.effects.bassHarmonics.speakerCutoffHz = bassHarmonicsSpeakerCutoffHz ?? 135
        }

        if let lowEndGuardAmount {
            config.effects.lowEndGuard.amountPercent = lowEndGuardAmount
            config.effects.lowEndGuard.isSet = true
        } else if !config.effects.lowEndGuard.isSet {
            config.effects.lowEndGuard = LowEndGuardEffectConfig()
        }

        if let spatialEnabled {
            if spatialEnabled { config.preamp -= 6.5 }
            config.effects.delay = DelayEffectConfig(timeMs: spatialEnabled ? 5 : 0, mix: spatialEnabled ? 4 : 0)
            config.effects.surround.width = spatialEnabled ? 30 : 0
            config.effects.surround.reverbMix = spatialEnabled ? 7 : 0
            config.effects.surround.rearAmount = spatialEnabled ? 56 : 0
            config.effects.surround.rearDelayMs = 4.2
            config.effects.surround.rearShadow = 58
        }
        config.effects.surround.headHeightCm = defaultSpatialHeadHeightCm
        config.effects.surround.displayAngleDegrees = defaultSpatialDisplayAngleDegrees
        if let listenerDistanceCm { config.effects.surround.listenerDistanceCm = listenerDistanceCm }
        if let spatialStrengthPercent { config.effects.surround.spatialStrengthPercent = spatialStrengthPercent }
        config.effects.surround.spatialModelIsSet = true

        if let bassFocusAmount {
            config.effects.bassFocus.amountPercent = bassFocusAmount
            config.effects.bassFocus.isSet = true
        }
        if let bassCompAmount {
            config.effects.bassComp.amountPercent = bassCompAmount
            config.effects.bassComp.isSet = true
        }
        if let bassCompCrossoverHz {
            config.effects.bassComp.crossoverHz = bassCompCrossoverHz
            config.effects.bassComp.isSet = true
        }
        if let softLimitDrive {
            config.effects.softLimit.drivePercent = softLimitDrive
            config.effects.softLimit.isSet = true
        }
        return config
    }

    var presetContent: String {
        var lines = [
            "# MiraEQ Hidden Processing Preset",
            "# Per-device overrides managed by the app. Omitted settings inherit the EQ preset."
        ]
        func append(_ name: String, _ fields: [(String, Float?)]) {
            let values = fields.compactMap { key, value in value.map { "\(key) \($0)" } }
            if !values.isEmpty { lines.append("Effect: \(name) \(values.joined(separator: " "))") }
        }
        append("Latency", [("target", latencyTargetMs)])
        if let spatialEnabled {
            append("Delay", [("time", spatialEnabled ? 5 : 0), ("mix", spatialEnabled ? 4 : 0)])
        }
        append("Surround", [
            ("width", spatialEnabled.map { $0 ? 30 : 0 }),
            ("reverb", spatialEnabled.map { $0 ? 7 : 0 }),
            ("rear", spatialEnabled.map { $0 ? 56 : 0 }),
            ("distance", listenerDistanceCm), ("strength", spatialStrengthPercent)
        ])
        append("BassHarmonics", [
            ("amount", bassHarmonicsAmount), ("cutoff", bassHarmonicsCutoffHz),
            ("speaker", bassHarmonicsSpeakerCutoffHz)
        ])
        append("LowEndGuard", [("amount", lowEndGuardAmount)])
        append("BassFocus", [("amount", bassFocusAmount)])
        append("BassComp", [("amount", bassCompAmount), ("crossover", bassCompCrossoverHz)])
        append("SoftLimit", [("drive", softLimitDrive)])
        return lines.joined(separator: "\n") + "\n"
    }
}

extension SurroundEffectConfig {
    var isEnabled: Bool { width > 0.0001 || rearAmount > 0.0001 || reverbMix > 0.0001 }
}
