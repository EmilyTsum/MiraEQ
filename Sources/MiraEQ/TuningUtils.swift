import Foundation

/// Shared numeric helpers for preset parsing and per-device tuning.
///
/// These were previously duplicated as private functions in each tuning file.
/// Centralizing them keeps clamping behavior identical across the app and
/// makes future range changes a single edit.
@inline(__always)
func clampTuning(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
    max(minValue, min(value, maxValue))
}

@inline(__always)
func clampedTuningValue(_ value: Float, min minValue: Float, max maxValue: Float) -> Float {
    clampTuning(value, min: minValue, max: maxValue)
}
