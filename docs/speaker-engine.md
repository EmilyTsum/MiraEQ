# Dedicated speaker engine

MiraEQ now has one signal path for the MacBook Air Rich profile:

```text
Capture / jitter buffer
  -> Loudness
  -> Bass Harmonics
  -> Bass Focus
  -> Low End Guard
  -> EQ (55 Hz high-pass + 10 parametric bands)
  -> Peak Limiter
  -> Physical output
```

Low-frequency enhancement and volume-dependent shaping run before the final EQ
voicing. A single peak limiter protects the completed signal, including the EQ
boosts. The global EQ gain is unity (0 dB). This is a gain setting, not automatic
normalization: protection can still reduce peaks dynamically.

`SpeakerEngineProfile` is the common normalization boundary for runtime routing
and effective-config inspection. `SpeakerDSPConfig` prepares finite coefficients
on the main actor. `RealtimeDSP` contains only the supported render stages and
preallocated state. `SpeakerAudioGraph` owns exactly three processing nodes:
source, EQ, and peak limiter. `AudioEngineManager` owns capture, device selection,
serialized start/stop, and standby rather than graph construction or DSP math.

Delay, reverb, spatial widening, rear/crosstalk processing, BassComp, SoftLimit,
Bass Mono, and the extra final compressor have no render code, playback nodes,
or effect buffers in this engine. The text parser still accepts old preset
fields so existing files remain readable. The profile clears those settings
before processing. Their former menu controls and diagnostics are removed.
Only the Rich preset is offered in the preset menu. Existing unused files remain
on disk; changing the device still honors routing/bypass.

The dedicated profile preserves the currently used 55 Hz high-pass, Harmonics
8%, Focus 70%, Loudness 50%, and Guard 45%. The global -4 dB offset is removed.
Reset uses this bundled profile. The disabled Bass Mono stage is not replaced
by another channel-folding operation.

## Buffering and latency

The preferred hardware quantum is 64 frames for the 1 ms target, clamped to the
physical device's supported range. The source retains one render quantum of
jitter margin plus the next block, instead of two extra quanta plus the target.
The ring's allocated capacity is 32 ms before power-of-two rounding (previously
80 ms); allocated capacity is not the actual queued delay. Startup prebuffering
tracks the chosen quantum. Both capture and output continue to use the same
physical device clock and aggregate drift compensation.

The native peak limiter uses a 3 ms attack/lookahead setting. The preceding
compressor added about 5.8 ms of native latency on this Mac and was redundant
for sample-peak containment in the tested material; it is removed. Diagnostics
report queue latency separately from `nativeEffectLatencyMs`. These values do
not claim a measured acoustic end-to-end latency.

## Verification and maintenance

`swift test -c release --filter SpeakerEngineTests` renders the actual graph
offline at 44.1 kHz. It exercises full-scale 64/125 Hz tones, multitone input,
impulses, high-frequency content, and silence at three system-volume settings.
It checks finite output, peak containment, the 11-band allocation, profile
normalization, and buffer-size range constraints. The same fixture emits mean
and p95 processing times per 128-frame block. Do not interpret those times as
whole-machine CPU utilization.

The previous 0.6.0 implementation was benchmarked separately with the same
release-build fixture and the saved active speaker preset. The old graph had
32 EQ slots, two dry spatial-effect nodes, and two protection units. Keep
performance conclusions scoped to that measured workload. Live installation
checks must additionally verify callback progress, underruns over time, and
standby/resume; the offline test does not prove scheduler stability.
