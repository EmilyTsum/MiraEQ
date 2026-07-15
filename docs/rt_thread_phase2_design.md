# Phase 2 Design: DSPResources Structural Isolation (Revised)

This document outlines the design for Phase 2 of the real-time audio thread safety improvements in [AudioEngine.swift](file:///Users/noxlume03/MiraEQ/Sources/MiraEQ/AudioEngine.swift). The goal of this phase is to isolate all dynamically allocated buffers and mutable DSP states into a single struct `DSPResources` and swap it atomically, ensuring zero ARC overhead and zero dynamic allocations/deallocations in the real-time thread.

---

## 1. Structure of `DSPResources`

All dynamic buffers and mutable states currently stored as global `nonisolated(unsafe) var`s will be grouped into a single struct, `DSPResources`. We will use a `struct` instead of a `class` to prevent Swift's automatic reference counting (ARC) overhead on the audio thread.

```swift
/// Dynamic buffers and mutable states for the DSP pipeline.
private struct DSPResources {
    // Immutable format metadata
    let sampleRate: Float
    let channelCount: Int
    
    // SPSC Ring Buffer (wrapped in Unmanaged to prevent ARC retain/release on the audio thread)
    let ringBuffer: Unmanaged<AudioRingBuffer>
    
    // Scratch and IO interleave buffers (pre-allocated, pointers are immutable constants)
    let scratchBuffer: UnsafeMutablePointer<Float>
    let scratchCapacity: Int
    let ioInterleaveBuffer: UnsafeMutablePointer<Float>
    let ioInterleaveCapacity: Int
    
    // Lowpass filter states (pre-allocated, pointers are immutable constants)
    let lowpassState: UnsafeMutablePointer<Float>
    let lowpassStateCapacity: Int
    let bassFocusLowpassState: UnsafeMutablePointer<Float>
    let bassFocusLowpassStateCapacity: Int
    let lowEndGuardLowpassState: UnsafeMutablePointer<Float>
    let lowEndGuardLowpassStateCapacity: Int
    
    // Rear surround delay lines and lowpass states
    let rearDelayLineLeft: UnsafeMutablePointer<Float>
    let rearDelayLineRight: UnsafeMutablePointer<Float>
    let rearDelayLineCapacity: Int
    var rearDelayLineIndex: Int             // Mutable index updated per-frame
    var rearLowpassLeft: Float              // Mutable filter state
    var rearLowpassRight: Float             // Mutable filter state
    
    // Dynamic states mutated on the real-time callback thread
    var bassFocusEnvelope: Float
    var bassFocusCurrentReductionDb: Float
    
    var lowEndGuardCurrentReductionDb: Float
    var lowEndGuardPeakDb: Float
    var lowEndGuardAverageReductionDb: Float
    var lowEndGuardObservedMaxReductionDb: Float
    var lowEndGuardMeasurementCount: UInt64
}
```

---

## 2. Division of Responsibilities

To keep state mutations clean and thread-safe, we establish a strict separation between `DSPConfig` and `DSPResources`:

| Characteristic | `DSPConfig` | `DSPResources` |
| :--- | :--- | :--- |
| **Purpose** | Parameter configuration set from UI (preset, sliders, toggle settings). | Internal memory buffers and mutable algorithm state. |
| **Mutability** | **Immutable** (read-only in the audio thread). | **Mutable** (delay lines, envelopes, filter states written in the audio thread). |
| **Frequency of updates** | High (whenever sliders are moved or presets load). | Very Low (only on output device/sample rate/channel count changes). |
| **Allocation** | Cheap (no buffer allocations, only simple value types). | Expensive (allocates large delay lines, ring buffers, filter states). |
| **Lifetime** | Retired immediately upon configuration swap. | Retired only upon engine stop or audio format change. |

---

## 3. Lifecycle and Retirement (RCU for Resources)

Just like `DSPConfig`, we will manage `DSPResources` using Read-Copy-Update (RCU).

1. **Active Reference**: Stored in a global atomic pointer:
   ```swift
   private let rtActiveResources = ManagedAtomic<UnsafeMutablePointer<DSPResources>?>(nil)
   ```
2. **Retirement Queue**: MainActor maintains a list of retired resources waiting to be freed, protected from multi-scheduling by a boolean flag:
   ```swift
   nonisolated(unsafe) private var rtRetiredResources: [UnsafeMutablePointer<DSPResources>] = []
   nonisolated(unsafe) private var rtResourceCleanupInProgress = false
   ```
3. **Reader Guard**: We reuse the same `rtReaderCount` that protects `DSPConfig`. Because the render callback loads both pointers inside the same reader guard block, we guarantee that neither the config nor the resources will be deallocated during callback execution.
4. **Deallocation**: Must run exclusively on the `MainActor`. Real-time thread must never call this.
   ```swift
   @MainActor
   private func deallocateResources(_ ptr: UnsafeMutablePointer<DSPResources>) {
       // Free all inner raw pointers
       ptr.pointee.scratchBuffer.deallocate()
       ptr.pointee.ioInterleaveBuffer.deallocate()
       ptr.pointee.lowpassState.deallocate()
       ptr.pointee.bassFocusLowpassState.deallocate()
       ptr.pointee.lowEndGuardLowpassState.deallocate()
       ptr.pointee.rearDelayLineLeft.deallocate()
       ptr.pointee.rearDelayLineRight.deallocate()
       
       // Release the ring buffer reference (decrement ARC count)
       ptr.pointee.ringBuffer.release()
       
       // Free the struct pointer itself
       ptr.deinitialize(count: 1)
       ptr.deallocate()
   }
   ```
5. **CleanUp Loop**:
   ```swift
   @MainActor
   private func cleanUpRetiredResources() {
       guard !rtRetiredResources.isEmpty else { return }
       
       if rtReaderCount.load(ordering: .acquiring) == 0 {
           for ptr in rtRetiredResources {
               deallocateResources(ptr)
           }
           rtRetiredResources.removeAll()
           rtResourceCleanupInProgress = false
       } else {
           if !rtResourceCleanupInProgress {
               rtResourceCleanupInProgress = true
               scheduleDeferredResourceCleanup()
           }
       }
   }

   @MainActor
   private func scheduleDeferredResourceCleanup() {
       Task {
           try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
           await MainActor.run {
               if rtReaderCount.load(ordering: .acquiring) == 0 {
                   for ptr in rtRetiredResources {
                       deallocateResources(ptr)
                   }
                   rtRetiredResources.removeAll()
                   rtResourceCleanupInProgress = false
               } else {
                   scheduleDeferredResourceCleanup()
               }
           }
       }
   }
   ```

---

## 4. Reallocation Strategy (Output / Format Changes)

When starting the engine or when output formats change, we allocate new resources on the MainActor/control thread and swap them:

```swift
private func setupResources(sampleRate: Double, channels: Int) {
    let preallocCapacity = 8192 * channels
    let lowpassCapacity = max(16, channels)
    let surroundCapacity = max(1024, Int(sampleRate * 0.06))
    
    // 1. Allocate raw pointers
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: preallocCapacity)
    let interleave = UnsafeMutablePointer<Float>.allocate(capacity: preallocCapacity)
    let lp = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let lpBF = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let lpLEG = UnsafeMutablePointer<Float>.allocate(capacity: lowpassCapacity)
    let delayL = UnsafeMutablePointer<Float>.allocate(capacity: surroundCapacity)
    let delayR = UnsafeMutablePointer<Float>.allocate(capacity: surroundCapacity)
    
    // Initialize pointers
    lp.initialize(repeating: 0, count: lowpassCapacity)
    lpBF.initialize(repeating: 0, count: lowpassCapacity)
    lpLEG.initialize(repeating: 0, count: lowpassCapacity)
    delayL.initialize(repeating: 0, count: surroundCapacity)
    delayR.initialize(repeating: 0, count: surroundCapacity)
    
    // 2. Instantiate SPSC Ring Buffer (passes ownership to resources)
    let ringBuf = AudioRingBuffer(capacityFrames: Int(sampleRate * 0.08), channels: channels)
    let ringBufUnmanaged = Unmanaged.passRetained(ringBuf)
    
    // 3. Create the DSPResources struct on the heap
    let newResources = DSPResources(
        sampleRate: Float(sampleRate),
        channelCount: channels,
        ringBuffer: ringBufUnmanaged,
        scratchBuffer: scratch,
        scratchCapacity: preallocCapacity,
        ioInterleaveBuffer: interleave,
        ioInterleaveCapacity: preallocCapacity,
        lowpassState: lp,
        lowpassStateCapacity: lowpassCapacity,
        bassFocusLowpassState: lpBF,
        bassFocusLowpassStateCapacity: lowpassCapacity,
        lowEndGuardLowpassState: lpLEG,
        lowEndGuardLowpassStateCapacity: lowpassCapacity,
        rearDelayLineLeft: delayL,
        rearDelayLineRight: delayR,
        rearDelayLineCapacity: surroundCapacity,
        rearDelayLineIndex: 0,
        rearLowpassLeft: 0,
        rearLowpassRight: 0,
        bassFocusEnvelope: 0,
        bassFocusCurrentReductionDb: 0,
        lowEndGuardCurrentReductionDb: 0,
        lowEndGuardPeakDb: -120,
        lowEndGuardAverageReductionDb: 0,
        lowEndGuardObservedMaxReductionDb: 0,
        lowEndGuardMeasurementCount: 0
    )
    
    let newResourcesPtr = UnsafeMutablePointer<DSPResources>.allocate(capacity: 1)
    newResourcesPtr.initialize(to: newResources)
    
    // 4. Swap atomically
    let oldResourcesPtr = rtActiveResources.exchange(newResourcesPtr, ordering: .acquiringAndReleasing)
    
    // 5. Retire old resources for deferred cleanup
    if let oldResourcesPtr = oldResourcesPtr {
        rtRetiredResources.append(oldResourcesPtr)
        cleanUpRetiredResources()
    }
}
```

---

## 5. No-ARC Real-Time Callback Access & Fallback

In the real-time audio thread:

1. **Reader Guard**: Increment `rtReaderCount` before loading config and resources.
2. **Fallback Strategy**: If `rtActiveResources` loads `nil` (e.g., before startup or after shutdown), we immediately zero-fill the output buffer list and return:
   ```swift
   guard let resourcesPtr = rtActiveResources.load(ordering: .acquiring) else {
       clearOutputBuffers(audioBufferList)
       return noErr
   }
   ```
3. **No-ARC Ring Buffer**: We access the ring buffer without reference counting:
   ```swift
   let ringBuf = resourcesPtr.pointee.ringBuffer.takeUnretainedValue()
   ```
4. **DSP Processing**: We pass `resourcesPtr` into the DSP processing methods:
   ```swift
   applyRealtimeEffects(scratch, frames: frames, channels: ch, config: config, resources: resourcesPtr)
   ```
5. **Direct Mutation**: Mutate states via the pointer directly (e.g. `resources.pointee.rearDelayLineIndex = index`). This modifies the heap instance directly without copying or ARC actions.
6. **Reader Release**: Decrement `rtReaderCount` on scope exit.
