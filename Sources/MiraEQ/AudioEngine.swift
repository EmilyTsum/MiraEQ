import Foundation
import Darwin
import os.log

// MARK: - AudioEngine Shared Primitives
//
// This file used to hold the entire audio stack (~2,400 lines). It now keeps
// only the small shared kernel used by both sides of the split:
//
//   RealtimeDSP.swift          lock-free DSP config/resources, render callback,
//                              effect implementations (real-time thread)
//   CoreAudioHelpers.swift     HAL property helpers, buffer sizing,
//                              diagnostics counters (control thread)
//   AudioEngineDiagnostics.swift  public diagnostics snapshot struct
//   AudioEngineManager.swift   engine lifecycle: tap, aggregate device,
//                              AVAudioEngine graph, auto-standby
//
// The math helpers below are plain float utilities used on both threads;
// they allocate nothing and block on nothing.

let appLog = OSLog(subsystem: AppInfo.logSubsystem, category: "audio")

let maximumRealtimeSampleRate: Float64 = 768_000
let maximumRealtimeChannelCount: UInt32 = 64
let defaultSpatialHeadHeightCm: Float = 38
let defaultSpatialDisplayAngleDegrees: Float = 150

func finiteOrDefault(_ value: Float, default defaultValue: Float) -> Float {
    value.isFinite ? value : defaultValue
}

func finiteClamped(_ value: Float, default defaultValue: Float, min minValue: Float, max maxValue: Float) -> Float {
    min(max(finiteOrDefault(value, default: defaultValue), minValue), maxValue)
}

func linearGain(forReductionDb reductionDb: Float) -> Float {
    powf(10, -max(reductionDb, 0) / 20)
}

func reductionDb(fromLinearGain gain: Float) -> Float {
    let clamped = min(max(finiteOrDefault(gain, default: 1), 0.000_001), 1)
    let db = -20 * log10f(clamped)
    return db < 0.005 ? 0 : db
}

func amplitudeDb(fromLinearAmplitude amplitude: Float) -> Float {
    20 * log10f(max(finiteOrDefault(amplitude, default: 0), 0.000_001))
}
