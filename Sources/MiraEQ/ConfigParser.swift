import Foundation
import AVFoundation

public struct EQBand: Equatable {
    public var filterType: AVAudioUnitEQFilterType
    public var frequency: Float
    public var bandwidth: Float // in octaves
    public var gain: Float // in dB
    public var bypass: Bool

    public init(filterType: AVAudioUnitEQFilterType, frequency: Float, bandwidth: Float, gain: Float, bypass: Bool) {
        self.filterType = filterType
        self.frequency = frequency
        self.bandwidth = bandwidth
        self.gain = gain
        self.bypass = bypass
    }
}

public struct EQConfig: Equatable {
    public var preamp: Float // in dB
    public var bands: [EQBand]
    public var effects: EffectConfig

    public init(preamp: Float, bands: [EQBand], effects: EffectConfig = EffectConfig()) {
        self.preamp = preamp
        self.bands = bands
        self.effects = effects
    }

}

public struct EffectConfig: Equatable {
    public var delay: DelayEffectConfig
    public var surround: SurroundEffectConfig
    public var bassHarmonics: BassHarmonicsEffectConfig
    public var bassFocus: BassFocusEffectConfig
    public var lowEndGuard: LowEndGuardEffectConfig
    public var latency: LatencyEffectConfig
    public var bassComp: BassCompEffectConfig
    public var softLimit: SoftLimitEffectConfig

    public init(
        delay: DelayEffectConfig = DelayEffectConfig(),
        surround: SurroundEffectConfig = SurroundEffectConfig(),
        bassHarmonics: BassHarmonicsEffectConfig = BassHarmonicsEffectConfig(),
        bassFocus: BassFocusEffectConfig = BassFocusEffectConfig(),
        lowEndGuard: LowEndGuardEffectConfig = LowEndGuardEffectConfig(),
        latency: LatencyEffectConfig = LatencyEffectConfig(),
        bassComp: BassCompEffectConfig = BassCompEffectConfig(),
        softLimit: SoftLimitEffectConfig = SoftLimitEffectConfig()
    ) {
        self.delay = delay
        self.surround = surround
        self.bassHarmonics = bassHarmonics
        self.bassFocus = bassFocus
        self.lowEndGuard = lowEndGuard
        self.latency = latency
        self.bassComp = bassComp
        self.softLimit = softLimit
    }

}

public struct DelayEffectConfig: Equatable {
    public var timeMs: Float
    public var feedback: Float
    public var mix: Float

    public init(timeMs: Float = 0, feedback: Float = 0, mix: Float = 0) {
        self.timeMs = timeMs
        self.feedback = feedback
        self.mix = mix
    }

    public var isEnabled: Bool {
        timeMs > 0 && mix > 0
    }
}

public struct SurroundEffectConfig: Equatable {
    public var width: Float
    public var reverbMix: Float
    public var rearAmount: Float
    public var rearDelayMs: Float
    public var rearShadow: Float
    public var listenerDistanceCm: Float
    public var headHeightCm: Float
    public var displayAngleDegrees: Float
    public var spatialStrengthPercent: Float
    public var spatialModelIsSet: Bool

    public init(
        width: Float = 0,
        reverbMix: Float = 0,
        rearAmount: Float = 0,
        rearDelayMs: Float = 4.5,
        rearShadow: Float = 55,
        listenerDistanceCm: Float = 40,
        headHeightCm: Float = 38,
        displayAngleDegrees: Float = 150,
        spatialStrengthPercent: Float = 100,
        spatialModelIsSet: Bool = false
    ) {
        self.width = width
        self.reverbMix = reverbMix
        self.rearAmount = rearAmount
        self.rearDelayMs = rearDelayMs
        self.rearShadow = rearShadow
        self.listenerDistanceCm = listenerDistanceCm
        self.headHeightCm = headHeightCm
        self.displayAngleDegrees = displayAngleDegrees
        self.spatialStrengthPercent = spatialStrengthPercent
        self.spatialModelIsSet = spatialModelIsSet
    }
}

public struct BassHarmonicsEffectConfig: Equatable {
    public var amount: Float
    public var cutoffHz: Float
    public var speakerCutoffHz: Float

    public init(amount: Float = 0, cutoffHz: Float = 140, speakerCutoffHz: Float? = nil) {
        self.amount = amount
        self.cutoffHz = cutoffHz
        self.speakerCutoffHz = speakerCutoffHz ?? cutoffHz
    }

    public var isEnabled: Bool {
        amount > 0
    }
}

public struct BassFocusEffectConfig: Equatable {
    public var amountPercent: Float
    public var thresholdDb: Float
    public var maxHighCutDb: Float
    public var isSet: Bool

    public init(amountPercent: Float = 0, thresholdDb: Float = -18, maxHighCutDb: Float = 7, isSet: Bool = false) {
        self.amountPercent = amountPercent
        self.thresholdDb = thresholdDb
        self.maxHighCutDb = maxHighCutDb
        self.isSet = isSet
    }

    public var isEnabled: Bool {
        amountPercent > 0.0001
    }
}

public struct LowEndGuardEffectConfig: Equatable {
    public var amountPercent: Float
    public var thresholdDb: Float
    public var cutoffHz: Float
    public var ratio: Float
    public var maxReductionDb: Float
    public var isSet: Bool

    public init(
        amountPercent: Float = 0,
        thresholdDb: Float = -18,
        cutoffHz: Float = 180,
        ratio: Float = 4,
        maxReductionDb: Float = 4.5,
        isSet: Bool = false
    ) {
        self.amountPercent = amountPercent
        self.thresholdDb = thresholdDb
        self.cutoffHz = cutoffHz
        self.ratio = ratio
        self.maxReductionDb = maxReductionDb
        self.isSet = isSet
    }

    public var isEnabled: Bool {
        amountPercent > 0.0001
    }
}

public struct LatencyEffectConfig: Equatable {
    public var targetMs: Float
    public var isSet: Bool

    public init(targetMs: Float = 12, isSet: Bool = false) {
        self.targetMs = targetMs
        self.isSet = isSet
    }
}

public struct BassCompEffectConfig: Equatable {
    public var amountPercent: Float
    public var crossoverHz: Float
    public var isSet: Bool

    public init(amountPercent: Float = 0, crossoverHz: Float = 200, isSet: Bool = false) {
        self.amountPercent = amountPercent
        self.crossoverHz = crossoverHz
        self.isSet = isSet
    }

    public var isEnabled: Bool {
        amountPercent > 0.0001
    }
}

public struct SoftLimitEffectConfig: Equatable {
    public var drivePercent: Float
    public var isSet: Bool

    public init(drivePercent: Float = 0, isSet: Bool = false) {
        self.drivePercent = drivePercent
        self.isSet = isSet
    }

    public var isEnabled: Bool {
        drivePercent > 0.0001
    }
}

public struct DeviceMapping: Equatable {
    public var pattern: String
    public var devicePresetFile: String?
    public var addOnPresetFile: String?
    
    public init(pattern: String, devicePresetFile: String?, addOnPresetFile: String? = nil) {
        self.pattern = pattern
        self.devicePresetFile = devicePresetFile
        self.addOnPresetFile = addOnPresetFile
    }
}

public class ConfigParser {
    public static func parse(content: String) -> (config: EQConfig, warnings: [String]) {
        var preamp: Float = 0.0
        var bands: [EQBand] = []
        var effects = EffectConfig()
        var warnings: [String] = []
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }
            
            if trimmed.lowercased().hasPrefix("preamp:") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 {
                    let valStr = parts[1].replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
                                         .trimmingCharacters(in: .whitespaces)
                    if let val = Float(valStr) {
                        preamp = val
                    } else {
                        warnings.append("Could not parse preamp value: \(parts[1])")
                    }
                } else {
                    warnings.append("Malformed preamp line: \(trimmed)")
                }
                continue
            }
            
            if trimmed.lowercased().hasPrefix("filter") {
                let parts = trimmed.components(separatedBy: ":")
                let filterContent: String
                if parts.count >= 2 {
                    filterContent = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                } else {
                    filterContent = trimmed
                }
                
                if let band = parseFilterLine(filterContent, warnings: &warnings) {
                    bands.append(band)
                }
            }

            if trimmed.lowercased().hasPrefix("effect") {
                let parts = trimmed.components(separatedBy: ":")
                let effectContent: String
                if parts.count >= 2 {
                    effectContent = parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                } else {
                    effectContent = trimmed
                }

                parseEffectLine(effectContent, into: &effects, warnings: &warnings)
            }
        }
        
        return (EQConfig(preamp: preamp, bands: bands, effects: effects), warnings)
    }
    
    public static func parseRouting(content: String) -> [DeviceMapping] {
        var mappings: [DeviceMapping] = []
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }
            
            let parts = trimmed.components(separatedBy: "=")
            if parts.count >= 2 {
                let pattern = parts[0].trimmingCharacters(in: .whitespaces)
                let routingValue = parts[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
                if !pattern.isEmpty && !routingValue.isEmpty {
                    let presetParts = routingValue.components(separatedBy: "|")
                    let devicePreset = normalizedPresetName(presetParts.first ?? "")
                    let addOnPreset = presetParts.count > 1 ? normalizedPresetName(presetParts[1]) : nil
                    mappings.append(DeviceMapping(
                        pattern: pattern,
                        devicePresetFile: devicePreset,
                        addOnPresetFile: addOnPreset
                    ))
                }
            }
        }
        return mappings
    }
    
    public static func writeRouting(mappings: [DeviceMapping]) -> String {
        var content = "# \(AppInfo.displayName) Device Routing Configuration\n"
        content += "# Format: DeviceNameOrUIDPattern = DevicePresetFile | HiddenProcessingPresetFile\n"
        content += "# Use None as the device preset to bypass processing for that device.\n"
        content += "# Evaluation is top-to-bottom. First match wins.\n\n"
        for mapping in mappings {
            let devicePreset = mapping.devicePresetFile ?? "None"
            if let addOnPreset = mapping.addOnPresetFile {
                content += "\(mapping.pattern) = \(devicePreset) | \(addOnPreset)\n"
            } else {
                content += "\(mapping.pattern) = \(devicePreset)\n"
            }
        }
        return content
    }

    private static func normalizedPresetName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.lowercased() != "none" && trimmed.lowercased() != "bypass" else { return nil }
        return trimmed
    }
    
    private static func parseFilterLine(_ line: String, warnings: inout [String]) -> EQBand? {
        let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return nil }
        
        let statusStr = tokens[0].uppercased()
        let bypass = (statusStr == "OFF")
        
        let typeStr = tokens[1].uppercased()
        let filterType: AVAudioUnitEQFilterType
        switch typeStr {
        case "PK": filterType = .parametric
        case "LSC": filterType = .lowShelf
        case "HSC": filterType = .highShelf
        case "LP": filterType = .lowPass
        case "HP": filterType = .highPass
        case "BP": filterType = .bandPass
        case "NO", "NOTCH": filterType = .bandStop
        default:
            filterType = .parametric
            warnings.append("Unknown filter type '\(typeStr)' in filter line: \(line)")
        }
        
        var frequency: Float = 1000.0
        var gain: Float = 0.0
        var bandwidth: Float = 1.0
        
        var i = 2
        while i < tokens.count {
            let key = tokens[i].lowercased()
            guard i + 1 < tokens.count else {
                warnings.append("Missing value for key '\(key)' in filter line: \(line)")
                break
            }
            let valStr = tokens[i+1]
            
            if key == "fc" {
                let cleanVal = valStr.replacingOccurrences(of: "Hz", with: "", options: .caseInsensitive)
                if let freq = Float(cleanVal) {
                    frequency = freq
                } else {
                    warnings.append("Could not parse frequency '\(valStr)' in filter line: \(line)")
                }
                if i + 2 < tokens.count && tokens[i+2].lowercased() == "hz" {
                    i += 1
                }
            } else if key == "gain" {
                let cleanVal = valStr.replacingOccurrences(of: "db", with: "", options: .caseInsensitive)
                if let g = Float(cleanVal) {
                    gain = g
                } else {
                    warnings.append("Could not parse gain '\(valStr)' in filter line: \(line)")
                }
                if i + 2 < tokens.count && tokens[i+2].lowercased() == "db" {
                    i += 1
                }
            } else if key == "q" {
                if let q = Float(valStr) {
                    bandwidth = qToBandwidth(q)
                } else {
                    warnings.append("Could not parse Q '\(valStr)' in filter line: \(line)")
                }
            } else if key == "bandwidth" || key == "bw" || key == "octave" {
                if let bw = Float(valStr) {
                    bandwidth = bw
                } else {
                    warnings.append("Could not parse bandwidth '\(valStr)' in filter line: \(line)")
                }
            }
            
            i += 2
        }
        
        return EQBand(filterType: filterType, frequency: frequency, bandwidth: bandwidth, gain: gain, bypass: bypass)
    }

    private static func parseEffectLine(_ line: String, into effects: inout EffectConfig, warnings: inout [String]) {
        let tokens = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard let effectName = tokens.first?.lowercased() else { return }
        let values = keyValueMap(from: Array(tokens.dropFirst()), warnings: &warnings, context: line)

        switch effectName {
        case "delay":
            effects.delay.timeMs = clamped(values["time"] ?? values["timems"] ?? values["ms"] ?? effects.delay.timeMs, min: 0, max: 500)
            effects.delay.feedback = clamped(values["feedback"] ?? values["fb"] ?? effects.delay.feedback, min: 0, max: 80)
            effects.delay.mix = clamped(values["mix"] ?? effects.delay.mix, min: 0, max: 60)
        case "surround", "spatial", "wide":
            effects.surround.width = clamped(values["width"] ?? values["amount"] ?? effects.surround.width, min: 0, max: 100)
            effects.surround.reverbMix = clamped(values["reverb"] ?? values["reverbmix"] ?? values["space"] ?? effects.surround.reverbMix, min: 0, max: 50)
            effects.surround.rearAmount = clamped(values["rear"] ?? values["behind"] ?? values["wrap"] ?? values["depth"] ?? effects.surround.rearAmount, min: 0, max: 100)
            effects.surround.rearDelayMs = clamped(values["reardelay"] ?? values["delay"] ?? values["depthms"] ?? effects.surround.rearDelayMs, min: 0.5, max: 30)
            effects.surround.rearShadow = clamped(values["shadow"] ?? values["tone"] ?? values["damping"] ?? effects.surround.rearShadow, min: 0, max: 100)
            if let distance = values["distance"] ?? values["distancecm"] ?? values["listener"] {
                effects.surround.listenerDistanceCm = clamped(distance, min: 25, max: 80)
                effects.surround.spatialModelIsSet = true
            }
            // Legacy spatial tokens; accepted for backward compatibility but ignored.
            _ = values["headheight"] ?? values["height"] ?? values["earheight"]
            _ = values["angle"] ?? values["displayangle"] ?? values["screenangle"]
            if let strength = values["strength"] ?? values["spatialstrength"] {
                effects.surround.spatialStrengthPercent = clamped(strength, min: 60, max: 140)
                effects.surround.spatialModelIsSet = true
            }
        case "bassharmonics", "bass_harmonics", "bass", "harmonics":
            effects.bassHarmonics.amount = clamped(values["amount"] ?? values["mix"] ?? effects.bassHarmonics.amount, min: 0, max: 100)
            effects.bassHarmonics.cutoffHz = clamped(values["cutoff"] ?? values["cutoffhz"] ?? values["freq"] ?? effects.bassHarmonics.cutoffHz, min: 50, max: 260)
            effects.bassHarmonics.speakerCutoffHz = clamped(
                values["speakercutoff"] ?? values["speakercutoffhz"] ?? values["speaker"] ?? effects.bassHarmonics.cutoffHz,
                min: 40,
                max: 260
            )
        case "bassfocus", "bass_focus", "inverse_loudness", "loudnesscomp":
            effects.bassFocus.amountPercent = clamped(values["amount"] ?? values["mix"] ?? values["strength"] ?? effects.bassFocus.amountPercent, min: 0, max: 100)
            effects.bassFocus.thresholdDb = clamped(values["threshold"] ?? values["thresholddb"] ?? values["start"] ?? effects.bassFocus.thresholdDb, min: -40, max: -6)
            effects.bassFocus.maxHighCutDb = clamped(values["highcut"] ?? values["cut"] ?? values["maxcut"] ?? effects.bassFocus.maxHighCutDb, min: 1, max: 12)
            effects.bassFocus.isSet = true
        case "lowendguard", "low_end_guard", "bassguard", "basslimiter":
            effects.lowEndGuard.amountPercent = clamped(values["amount"] ?? values["mix"] ?? values["strength"] ?? effects.lowEndGuard.amountPercent, min: 0, max: 100)
            effects.lowEndGuard.thresholdDb = clamped(values["threshold"] ?? values["thresholddb"] ?? values["start"] ?? effects.lowEndGuard.thresholdDb, min: -36, max: -6)
            effects.lowEndGuard.cutoffHz = clamped(values["cutoff"] ?? values["cutoffhz"] ?? values["freq"] ?? effects.lowEndGuard.cutoffHz, min: 90, max: 260)
            effects.lowEndGuard.ratio = clamped(values["ratio"] ?? effects.lowEndGuard.ratio, min: 1.5, max: 12)
            effects.lowEndGuard.maxReductionDb = clamped(values["maxreduction"] ?? values["maxreductiondb"] ?? values["reduction"] ?? effects.lowEndGuard.maxReductionDb, min: 1, max: 10)
            effects.lowEndGuard.isSet = true
        case "latency", "buffer":
            effects.latency.targetMs = clamped(values["target"] ?? values["time"] ?? values["ms"] ?? effects.latency.targetMs, min: 1, max: 80)
            effects.latency.isSet = true
        case "basscomp":
            effects.bassComp.amountPercent = clamped(values["amount"] ?? values["mix"] ?? values["strength"] ?? effects.bassComp.amountPercent, min: 0, max: 100)
            effects.bassComp.crossoverHz = clamped(values["crossover"] ?? values["cutoff"] ?? values["freq"] ?? effects.bassComp.crossoverHz, min: 90, max: 260)
            effects.bassComp.isSet = true
        case "softlimit":
            effects.softLimit.drivePercent = clamped(values["drive"] ?? values["amount"] ?? values["mix"] ?? effects.softLimit.drivePercent, min: 0, max: 100)
            effects.softLimit.isSet = true
        default:
            warnings.append("Unknown effect '\(effectName)' in effect line: \(line)")
        }
    }

    private static func keyValueMap(from tokens: [String], warnings: inout [String], context line: String) -> [String: Float] {
        let knownKeys: Set<String> = [
            "time", "timems", "ms",
            "target",
            "feedback", "fb",
            "mix",
            "width", "amount",
            "reverb", "reverbmix", "space",
            "rear", "behind", "wrap", "depth",
            "reardelay", "delay", "depthms",
            "shadow", "tone", "damping",
            "distance", "distancecm", "listener",
            "headheight", "height", "earheight",
            "angle", "displayangle", "screenangle",
            "strength", "spatialstrength",
            "cutoff", "cutoffhz", "freq",
            "speakercutoff", "speakercutoffhz", "speaker",
            "threshold", "thresholddb", "start",
            "highcut", "cut", "maxcut",
            "ratio",
            "maxreduction", "maxreductiondb", "reduction",
            "crossover",
            "drive"
        ]
        let unitTokens: Set<String> = ["ms", "hz", "db", "%"]

        var values: [String: Float] = [:]
        var i = 0
        while i < tokens.count {
            let key = tokens[i].lowercased()
            guard knownKeys.contains(key) else {
                i += 1
                continue
            }
            guard i + 1 < tokens.count else {
                warnings.append("Missing value for key '\(key)' in effect line: \(line)")
                break
            }
            var rawValue = tokens[i + 1].lowercased()
            rawValue = rawValue.replacingOccurrences(of: "ms", with: "")
            rawValue = rawValue.replacingOccurrences(of: "hz", with: "")
            rawValue = rawValue.replacingOccurrences(of: "db", with: "")
            rawValue = rawValue.replacingOccurrences(of: "%", with: "")
            if let value = Float(rawValue) {
                values[key] = value
            } else {
                warnings.append("Could not parse value for key '\(key)': \(tokens[i + 1]) in effect line: \(line)")
            }
            i += 2
            // Skip optional trailing unit token(s) (e.g. "dB", "Hz") before the next key.
            while i < tokens.count && unitTokens.contains(tokens[i].lowercased()) {
                i += 1
            }
        }
        return values
    }

    private static func clamped(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
        clampTuning(value, min: minValue, max: maxValue)
    }
    
    private static func qToBandwidth(_ q: Float) -> Float {
        guard q > 0.01 else { return 1.0 }
        let x = Double(1.0 / (2.0 * q))
        let arcsinh = log(x + sqrt(x * x + 1.0))
        let bw = (2.0 / log(2.0)) * arcsinh
        return Float(max(0.05, min(bw, 5.0)))
    }
}
