import Foundation

enum VerificationFailure: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

private struct TuningSet {
    let processing: ProcessingTuning
    let spatial: SpatialTuning
    let bassFocus: BassFocusTuning
    let bassPower: BassPowerTuning
}

func effectiveConfig(
    devicePresetName: String,
    addOnPresetName: String
) throws -> EQConfig {
    let (deviceConfig, addOnConfig) = try loadPresetPair(
        devicePresetName: devicePresetName,
        addOnPresetName: addOnPresetName
    )
    let tunings = TuningSet(
        processing: ProcessingTuning(effects: addOnConfig.effects),
        spatial: SpatialTuning(surround: addOnConfig.effects.surround),
        bassFocus: BassFocusTuning(effects: addOnConfig.effects),
        bassPower: BassPowerTuning(effects: addOnConfig.effects)
    )
    return makeEffectiveConfig(base: deviceConfig, tunings: tunings)
}

func verifyRoundTrip(
    devicePresetName: String,
    addOnPresetName: String
) throws {
    let (deviceConfig, addOnConfig) = try loadPresetPair(
        devicePresetName: devicePresetName,
        addOnPresetName: addOnPresetName
    )

    let originalTunings = TuningSet(
        processing: ProcessingTuning(effects: addOnConfig.effects),
        spatial: SpatialTuning(surround: addOnConfig.effects.surround),
        bassFocus: BassFocusTuning(effects: addOnConfig.effects),
        bassPower: BassPowerTuning(effects: addOnConfig.effects)
    )

    let originalEffective = makeEffectiveConfig(base: deviceConfig, tunings: originalTunings)

    let serialized = hiddenTuningPresetContent(
        processingTuning: originalTunings.processing,
        spatialTuning: originalTunings.spatial,
        bassFocusTuning: originalTunings.bassFocus,
        bassPowerTuning: originalTunings.bassPower
    )

    let (reparsedConfig, reparsedWarnings) = ConfigParser.parse(content: serialized)
    guard reparsedWarnings.isEmpty else {
        throw VerificationFailure.message("Round-trip parse produced warnings: \(reparsedWarnings)")
    }

    let roundTripTunings = TuningSet(
        processing: ProcessingTuning(effects: reparsedConfig.effects),
        spatial: SpatialTuning(surround: reparsedConfig.effects.surround),
        bassFocus: BassFocusTuning(effects: reparsedConfig.effects),
        bassPower: BassPowerTuning(effects: reparsedConfig.effects)
    )

    let roundTripEffective = makeEffectiveConfig(base: deviceConfig, tunings: roundTripTunings)

    guard originalEffective == roundTripEffective else {
        throw VerificationFailure.message(
            "Round-trip effective config mismatch for \(devicePresetName) / \(addOnPresetName)"
        )
    }
}

private func makeEffectiveConfig(base: EQConfig, tunings: TuningSet) -> EQConfig {
    return base
        .applying(processingTuning: tunings.processing, spatialTuning: tunings.spatial)
        .applying(bassFocusTuning: tunings.bassFocus)
        .applying(bassPowerTuning: tunings.bassPower)
}

private func loadPresetPair(
    devicePresetName: String,
    addOnPresetName: String
) throws -> (device: EQConfig, addOn: EQConfig) {
    let configDir = configDirectory()
    let routingURL = configDir.appendingPathComponent("config.txt")
    let routingContent = try String(contentsOf: routingURL, encoding: .utf8)
    let mappings = ConfigParser.parseRouting(content: routingContent)

    guard let mapping = mappings.first(where: {
        $0.devicePresetFile == devicePresetName && $0.addOnPresetFile == addOnPresetName
    }) else {
        throw VerificationFailure.message("Mapping not found for \(devicePresetName) / \(addOnPresetName)")
    }

    let devicePresetURL = configDir
        .appendingPathComponent("presets/device")
        .appendingPathComponent(mapping.devicePresetFile ?? "")
    let addOnPresetURL = configDir
        .appendingPathComponent("presets/addons")
        .appendingPathComponent(mapping.addOnPresetFile ?? "")

    let deviceContent = try String(contentsOf: devicePresetURL, encoding: .utf8)
    let addOnContent = try String(contentsOf: addOnPresetURL, encoding: .utf8)

    let (deviceConfig, deviceWarnings) = ConfigParser.parse(content: deviceContent)
    let (addOnConfig, addOnWarnings) = ConfigParser.parse(content: addOnContent)

    guard deviceWarnings.isEmpty else {
        throw VerificationFailure.message("Device preset \(devicePresetName) produced warnings: \(deviceWarnings)")
    }
    guard addOnWarnings.isEmpty else {
        throw VerificationFailure.message("Add-on preset \(addOnPresetName) produced warnings: \(addOnWarnings)")
    }

    return (deviceConfig, addOnConfig)
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

private func configDirectory() -> URL {
    // Keep the path identical to the app runtime (AppInfo, case-sensitive).
    // The previous hardcoded ".config/miraeq" (lowercase) mismatched
    // AppInfo's "MiraEQ" and broke --print-effective-config on
    // case-sensitive filesystems.
    let expanded = (AppInfo.configDirectoryPath as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded, isDirectory: true)
}
