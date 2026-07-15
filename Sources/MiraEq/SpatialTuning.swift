import Foundation

public struct SpatialTuning: Equatable {
    public var listenerDistanceCm: Float
    public var distanceIsSet: Bool
    public var strengthPercent: Float
    public var strengthIsSet: Bool

    // Baked internal constants for compatibility with the audio engine.
    public var headHeightCm: Float { 38 }
    public var displayAngleDegrees: Float { 150 }

    public static let `default` = SpatialTuning(
        listenerDistanceCm: 40,
        distanceIsSet: false,
        strengthPercent: 100,
        strengthIsSet: false
    )

    public init(
        listenerDistanceCm: Float,
        distanceIsSet: Bool = false,
        strengthPercent: Float,
        strengthIsSet: Bool = false
    ) {
        self.listenerDistanceCm = listenerDistanceCm
        self.distanceIsSet = distanceIsSet
        self.strengthPercent = strengthPercent
        self.strengthIsSet = strengthIsSet
    }

    init(surround: SurroundEffectConfig) {
        self.init(
            listenerDistanceCm: clampedTuningValue(surround.listenerDistanceCm, min: 25, max: 80),
            distanceIsSet: surround.spatialModelIsSet,
            strengthPercent: clampedTuningValue(surround.spatialStrengthPercent, min: 60, max: 140),
            strengthIsSet: surround.spatialModelIsSet
        )
    }
}

public extension EQConfig {
    func applying(spatialTuning: SpatialTuning) -> EQConfig {
        var tuned = self
        tuned.effects.surround.apply(spatialTuning: spatialTuning)
        return tuned
    }
}

public extension SurroundEffectConfig {
    mutating func apply(spatialTuning: SpatialTuning) {
        // Head height and display angle are baked as internal constants;
        // only distance and strength are user-facing tuning parameters.
        headHeightCm = 38
        displayAngleDegrees = 150

        if spatialTuning.distanceIsSet {
            listenerDistanceCm = spatialTuning.listenerDistanceCm
        }
        if spatialTuning.strengthIsSet {
            spatialStrengthPercent = spatialTuning.strengthPercent
        }
        spatialModelIsSet = true
    }
}

private func clamped(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
    max(minValue, min(value, maxValue))
}

private func clampedTuningValue(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
    max(minValue, min(value, maxValue))
}
