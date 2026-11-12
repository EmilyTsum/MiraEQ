/// HAL reports whether an output stream is running, not whether its samples
/// are audible. Keep processing a live stream: after tearing down the tap,
/// silence -> sound on that same stream cannot be observed without capturing.
enum AutoStandbyPolicy {
    static let silenceDelaySeconds: Double = 120

    static func shouldEnter(
        muted: Bool,
        outputVolume: Float?,
        silenceStandbyEnabled: Bool,
        silentSeconds: Double,
        hasRunningOutput: Bool?
    ) -> Bool {
        if outputIsSilenced(muted: muted, volume: outputVolume) { return true }
        return silenceStandbyEnabled
            && silentSeconds >= silenceDelaySeconds
            && hasRunningOutput == false
    }

    static func shouldResume(muted: Bool, outputVolume: Float?, hasRunningOutput: Bool?) -> Bool {
        !outputIsSilenced(muted: muted, volume: outputVolume) && hasRunningOutput == true
    }

    private static func outputIsSilenced(muted: Bool, volume: Float?) -> Bool {
        // Some outputs expose no volume control. Unknown is not zero volume.
        muted || volume.map { $0 <= 0.000_1 } == true
    }
}
