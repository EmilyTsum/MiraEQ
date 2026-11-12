import Foundation

enum VerificationFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

func effectiveConfig(
    devicePresetName: String,
    addOnPresetName: String,
    store: ConfigurationStore = ConfigurationStore()
) throws -> EQConfig {
    let pair = try loadPresetPair(devicePresetName: devicePresetName, addOnPresetName: addOnPresetName, store: store)
    return SpeakerEngineProfile.prepare(pair.tuning.applying(to: pair.device))
}

func verifyRoundTrip(
    devicePresetName: String,
    addOnPresetName: String,
    store: ConfigurationStore = ConfigurationStore()
) throws {
    let pair = try loadPresetPair(devicePresetName: devicePresetName, addOnPresetName: addOnPresetName, store: store)
    let (reparsed, warnings) = ConfigParser.parseTuning(content: pair.tuning.presetContent)
    guard warnings.isEmpty else {
        throw VerificationFailure.message("Round-trip parse produced warnings: \(warnings)")
    }
    guard pair.tuning.applying(to: pair.device) == reparsed.applying(to: pair.device) else {
        throw VerificationFailure.message("Round-trip effective config mismatch for \(devicePresetName) / \(addOnPresetName)")
    }
}

private func loadPresetPair(
    devicePresetName: String,
    addOnPresetName: String,
    store: ConfigurationStore
) throws -> (device: EQConfig, tuning: DeviceTuning) {
    let mappings = try store.loadRouting()
    guard mappings.contains(where: {
        $0.devicePresetFile == devicePresetName && $0.addOnPresetFile == addOnPresetName
    }) else {
        throw VerificationFailure.message("Mapping not found for \(devicePresetName) / \(addOnPresetName)")
    }
    let device = ConfigParser.parse(content: try store.devicePresetContent(named: devicePresetName))
    let tuning = ConfigParser.parseTuning(content: try store.tuningContent(named: addOnPresetName))
    guard device.warnings.isEmpty, tuning.warnings.isEmpty else {
        throw VerificationFailure.message("Preset warnings: \(device.warnings + tuning.warnings)")
    }
    return (device.config, tuning.tuning)
}

func printEffectiveConfig(_ config: EQConfig) {
    print("preamp: \(config.preamp)")
    print("latency.targetMs: \(config.effects.latency.targetMs) (isSet: \(config.effects.latency.isSet))")
    print("delay.timeMs: \(config.effects.delay.timeMs)")
    print("delay.feedback: \(config.effects.delay.feedback)")
    print("delay.mix: \(config.effects.delay.mix)")
    print("bassHarmonics.amount: \(config.effects.bassHarmonics.amount)")
    print("bassHarmonics.cutoffHz: \(config.effects.bassHarmonics.cutoffHz)")
    print("bassHarmonics.speakerCutoffHz: \(config.effects.bassHarmonics.speakerCutoffHz)")
    print("lowEndGuard.amountPercent: \(config.effects.lowEndGuard.amountPercent)")
    print("lowEndGuard.thresholdDb: \(config.effects.lowEndGuard.thresholdDb)")
    print("lowEndGuard.cutoffHz: \(config.effects.lowEndGuard.cutoffHz)")
    print("lowEndGuard.ratio: \(config.effects.lowEndGuard.ratio)")
    print("lowEndGuard.maxReductionDb: \(config.effects.lowEndGuard.maxReductionDb)")
    print("lowEndGuard.isSet: \(config.effects.lowEndGuard.isSet)")
    print("surround.width: \(config.effects.surround.width)")
    print("surround.reverbMix: \(config.effects.surround.reverbMix)")
    print("surround.rearAmount: \(config.effects.surround.rearAmount)")
    print("surround.rearDelayMs: \(config.effects.surround.rearDelayMs)")
    print("surround.rearShadow: \(config.effects.surround.rearShadow)")
    print("surround.listenerDistanceCm: \(config.effects.surround.listenerDistanceCm)")
    print("surround.headHeightCm: \(config.effects.surround.headHeightCm)")
    print("surround.displayAngleDegrees: \(config.effects.surround.displayAngleDegrees)")
    print("surround.spatialStrengthPercent: \(config.effects.surround.spatialStrengthPercent)")
    print("surround.spatialModelIsSet: \(config.effects.surround.spatialModelIsSet)")
    print("bassFocus.amountPercent: \(config.effects.bassFocus.amountPercent)")
    print("bassFocus.thresholdDb: \(config.effects.bassFocus.thresholdDb)")
    print("bassFocus.maxHighCutDb: \(config.effects.bassFocus.maxHighCutDb)")
    print("bassFocus.isSet: \(config.effects.bassFocus.isSet)")
    print("bassComp.amountPercent: \(config.effects.bassComp.amountPercent)")
    print("bassComp.crossoverHz: \(config.effects.bassComp.crossoverHz)")
    print("bassComp.isSet: \(config.effects.bassComp.isSet)")
    print("softLimit.drivePercent: \(config.effects.softLimit.drivePercent)")
    print("softLimit.isSet: \(config.effects.softLimit.isSet)")
    print("bassMono.cutoffHz: \(config.effects.bassMono.cutoffHz)")
    print("loudness.amount: \(config.effects.loudness.amount)")
    print("bands.count: \(config.bands.count)")
}
