# MacBook Air 13 Surround Model

This note records the geometry used by the MacBook Air 13 surround preset and
the Surround Position menu.

## Sources

- Apple MacBook Air technical specifications: 13.6-inch 2560-by-1664 display,
  four-speaker sound system, 30.41 cm width, 21.5 cm depth.
  https://www.apple.com/macbook-air/specs/
- HRTF localization cues: ITD, ILD, and spectral cues are the main binaural
  cues used for localization.
  https://arxiv.org/abs/2203.03166
- OpenAL Soft: a practical open source 3D audio implementation with HRTF
  support and distance/spatial audio concepts.
  https://github.com/kcat/openal-soft

## Current Constraint

MiraEq currently captures a stereo global process tap and the app diagnostics
show a 2-channel processing format on the tested setup. Apple's official spec
confirms a four-speaker sound system, but it does not imply that CoreAudio
exposes four independently addressable built-in speaker channels to this app.

So this model does not directly drive four physical speakers. It feeds a better
stereo transaural/HRTF-style signal into the built-in speaker system, which can
then be rendered by Apple's internal speaker/DSP path.

## Geometry

Official and derived MacBook Air 13 dimensions:

- Chassis width: 30.41 cm
- Chassis depth: 21.5 cm
- Display diagonal: 13.6 in
- Display pixel ratio: 2560:1664
- Derived active display width: about 28.96 cm
- Derived active display height: about 18.83 cm

Listener model:

- Listener distance from screen: 40 cm
- Head/ear height above the speaker plane: 38 cm
- Display open angle: 150 degrees internal, matching the user's rough
  210-degree outside-angle estimate
- Ear spacing: 18 cm
- Effective left/right speaker acoustic-center spacing: 26 cm
- Speed of sound: 343 m/s

The effective speaker spacing is an estimate, not an Apple-published internal
dimension. It treats the four physical speakers as two left/right acoustic
arrays because MiraEq receives and renders stereo.

## Cross-Ear Delay

Let:

- `S = 0.26 m` speaker spacing
- `E = 0.18 m` ear spacing
- `D = 0.40 m` listener distance
- `H = 0.38 m` head height

Path estimates:

```text
ipsilateral  = sqrt(((S - E) / 2)^2 + D^2 + H^2)
contralateral = sqrt(((S + E) / 2)^2 + D^2 + H^2)
delay = (contralateral - ipsilateral) / 343
```

For the default model:

- Ipsilateral path: about 0.553 m
- Contralateral path: about 0.594 m
- Path difference: about 0.041 m
- Cross-ear delay: about 0.119 ms
- 48 kHz delay: about 5.7 samples, rounded to 6 samples

This delay is used for the crosstalk cancellation part of the rear-wrap effect.
The larger rear delay in the preset, around 4 ms, is not the physical
left-to-right speaker delay. It is a psychoacoustic rear/reflection cue.

## Preset Mapping

`MiraEq_MacBook_Air_13_Geometry_Surround.txt` uses the model above:

- Rear wrap: 56
- Rear delay: 4.2 ms
- Head shadow: 58
- Stereo width: 30
- Reverb: 7
- Latency target: 5 ms

The older Ring Surround and Rear Wrap Surround presets were removed so this is
the only surround add-on preset shipped by default.

## Menu Tuning

The Surround Position menu deliberately exposes a small number of stable choices:

- Distance: 35, 40, 45, 50 cm
- Head height: 30, 38, 44 cm
- Display angle: 120, 135, 150 degrees
- Strength: 80, 100, 120 percent

These settings are saved in UserDefaults and applied on top of the selected
device/add-on presets without requiring a full routing config edit.
