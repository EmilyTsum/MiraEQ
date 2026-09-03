import Foundation

// MARK: - Engine Diagnostics Snapshot
//
// Plain value snapshot of engine health, produced by AudioEngineManager on
// the main actor and consumed by the menu (StatusMenu) and the diagnostics
// file (DiagnosticsReporter).

public struct AudioEngineDiagnostics {
    public let isActive: Bool
    public let engineRunning: Bool
    public let activeDeviceName: String?
    public let sampleRate: Double
    public let channels: UInt32
    public let targetLatencyMs: Double
    public let bufferedLatencyMs: Double
    public let queuedFrames: Int
    public let queuedBeforeRenderMs: Double
    public let queuedBeforeRenderFrames: Int
    public let bufferCapacityMs: Double
    public let bufferFillPercent: Double
    public let requestedBufferFrames: UInt32
    public let outputBufferFrames: UInt32
    public let aggregateBufferFrames: UInt32
    public let effectDelayMs: Double
    public let renderCallbacks: UInt64
    public let idleRenderCallbacks: UInt64
    public let ioCallbacks: UInt64
    public let underruns: UInt64
    public let underrunFrames: UInt64
    public let lastUnderrunFrames: UInt64
    public let droppedFrames: UInt64
    public let lastInputFrameCount: UInt64
    public let lastRenderFrameCount: UInt64
    public let lastRenderDurationMs: Double
    public let maxRenderDurationMs: Double
    public let renderBudgetMs: Double
    public let spatialListenerDistanceCm: Float
    public let spatialHeadHeightCm: Float
    public let spatialDisplayAngleDegrees: Float
    public let spatialStrengthPercent: Float
    public let crossTalkDelayMs: Double
    public let outputVolumePercent: Float
    public let bassFocusAmountPercent: Float
    public let bassFocusReductionDb: Float
    public let lowEndGuardReductionDb: Float
    public let lowEndGuardAverageReductionDb: Float
    public let lowEndGuardMaxReductionDb: Float
    public let lowEndGuardPeakDb: Float
    public let finalSafetyCompressionDb: Float
    public let startedAt: Date?
    public let startCount: UInt64
}
