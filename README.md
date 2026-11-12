# MiraEQ

Menu bar system-wide audio processor with one dedicated MacBook Air Rich speaker engine. Captures system audio with a Core Audio process tap and applies low-frequency shaping, an 11-stage EQ, and final peak protection.

## Install

```sh
brew tap EmilyTsum/tap
brew install --cask miraeq
```

MiraEQ is ad-hoc signed (not notarized). If Gatekeeper blocks the first launch:

```sh
xattr -cr /Applications/MiraEQ.app
```

## Features

- One Rich speaker preset: 55 Hz high-pass and 10 parametric EQ bands, global gain 0 dB
- Loudness, bass harmonics/focus, low-end guard, and one final peak limiter
- Dedicated low-latency graph with no spatial, delay/reverb, BassComp, SoftLimit, or Bass Mono processing
- Auto-standby: after 2 minutes of silence with no active output streams (toggleable in the menu), or whenever the output is muted / at zero volume, audio capture stops; processing resumes automatically when playback starts. Players that keep a silent output stream open stay processed, so resuming on that same stream never loses EQ. Original audio keeps playing during the seamless switchover.
- Preset files hot-reload: editing `config.txt` or any preset file re-applies the configuration immediately
- Config and presets live in `~/.config/MiraEQ`

## Build

```sh
scripts/build_app.sh <version>   # produces dist/MiraEQ.app and dist/MiraEQ-<version>.dmg
```

Requires macOS 14.2+.

## Development

The executable product is `MiraEQ`. With Xcode selected:

```sh
swift build
swift test
```

If `xcode-select` points to Command Line Tools and XCTest is unavailable, use
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

See [Speaker engine](docs/speaker-engine.md) and [Architecture](docs/architecture.md) for configuration ownership, routing,
standby behavior, and the boundary with the realtime audio code.
