import Foundation

public struct BassPowerTuning: Equatable {
    public var bassCompAmountPercent: Float
    public var bassCompAmountIsSet: Bool
    public var bassCompCrossoverHz: Float
    public var bassCompCrossoverIsSet: Bool
    public var softLimitDrivePercent: Float
    public var softLimitDriveIsSet: Bool

    public static let `default` = BassPowerTuning(
        bassCompAmountPercent: 0,
        bassCompAmountIsSet: false,
        bassCompCrossoverHz: 200,
        bassCompCrossoverIsSet: false,
        softLimitDrivePercent: 0,
        softLimitDriveIsSet: false
    )

    public init(
        bassCompAmountPercent: Float,
        bassCompAmountIsSet: Bool = false,
        bassCompCrossoverHz: Float,
        bassCompCrossoverIsSet: Bool = false,
        softLimitDrivePercent: Float,
        softLimitDriveIsSet: Bool = false
    ) {
        self.bassCompAmountPercent = bassCompAmountPercent
        self.bassCompAmountIsSet = bassCompAmountIsSet
        self.bassCompCrossoverHz = bassCompCrossoverHz
        self.bassCompCrossoverIsSet = bassCompCrossoverIsSet
        self.softLimitDrivePercent = softLimitDrivePercent
        self.softLimitDriveIsSet = softLimitDriveIsSet
    }

    init(effects: EffectConfig) {
        let bassCompIsSet = effects.bassComp.isSet
        let softLimitIsSet = effects.softLimit.isSet

        self.init(
            bassCompAmountPercent: clampedTuningValue(effects.bassComp.amountPercent, min: 0, max: 100),
            bassCompAmountIsSet: bassCompIsSet,
            bassCompCrossoverHz: clampedTuningValue(effects.bassComp.crossoverHz, min: 90, max: 260),
            bassCompCrossoverIsSet: bassCompIsSet,
            softLimitDrivePercent: clampedTuningValue(effects.softLimit.drivePercent, min: 0, max: 100),
            softLimitDriveIsSet: softLimitIsSet
        )
    }
}

public extension EQConfig {
    func applying(bassPowerTuning: BassPowerTuning) -> EQConfig {
        var tuned = self

        // BassComp amount: hidden tuning > base preset > bypass
        if bassPowerTuning.bassCompAmountIsSet {
            tuned.effects.bassComp.amountPercent = bassPowerTuning.bassCompAmountPercent
            tuned.effects.bassComp.isSet = true
        } else if !tuned.effects.bassComp.isSet {
            tuned.effects.bassComp.amountPercent = 0
        }

        // BassComp crossover: hidden tuning > base preset > default
        if bassPowerTuning.bassCompCrossoverIsSet {
            tuned.effects.bassComp.crossoverHz = bassPowerTuning.bassCompCrossoverHz
            tuned.effects.bassComp.isSet = true
        } else if !tuned.effects.bassComp.isSet {
            tuned.effects.bassComp.crossoverHz = 200
        }

        // SoftLimit drive: hidden tuning > base preset > bypass
        if bassPowerTuning.softLimitDriveIsSet {
            tuned.effects.softLimit.drivePercent = bassPowerTuning.softLimitDrivePercent
            tuned.effects.softLimit.isSet = true
        } else if !tuned.effects.softLimit.isSet {
            tuned.effects.softLimit.drivePercent = 0
        }

        return tuned
    }
}

private func clampedTuningValue(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
    max(minValue, min(value, maxValue))
}
