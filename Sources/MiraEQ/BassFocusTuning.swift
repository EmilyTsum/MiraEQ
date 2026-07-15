import Foundation

public struct BassFocusTuning: Equatable {
    public var amountPercent: Float
    public var amountIsSet: Bool

    public static let `default` = BassFocusTuning(amountPercent: 50, amountIsSet: false)

    public init(amountPercent: Float, amountIsSet: Bool = false) {
        self.amountPercent = amountPercent
        self.amountIsSet = amountIsSet
    }

    init(effects: EffectConfig) {
        self.init(
            amountPercent: clampedTuningValue(effects.bassFocus.amountPercent, min: 0, max: 100),
            amountIsSet: effects.bassFocus.isSet
        )
    }
}

public extension EQConfig {
    func applying(bassFocusTuning: BassFocusTuning) -> EQConfig {
        var tuned = self
        if bassFocusTuning.amountIsSet {
            tuned.effects.bassFocus.amountPercent = bassFocusTuning.amountPercent
            tuned.effects.bassFocus.isSet = true
        }
        return tuned
    }
}

private func clamped(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
    max(minValue, min(value, maxValue))
}

private func clampedTuningValue(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
    max(minValue, min(value, maxValue))
}
