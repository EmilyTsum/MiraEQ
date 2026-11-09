# MiraEQ

Menu bar system-wide equalizer for macOS. Taps system audio with a Core Audio process tap, applies per-device EQ presets and spatial/bass processing, and plays back through the selected output device.

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

- Per-device EQ presets (32-band) with automatic routing on default-device change
- Spatial model, bass harmonics/focus/comp, low-end guard, final safety limiter
- Auto-standby: when playback is silent for 2 minutes (toggleable in the menu) or the output is muted / at zero volume (always), audio capture stops so the system audio indicator disappears; processing resumes automatically when playback restarts, with the original audio kept playing during the seamless switchover
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

See [Architecture](docs/architecture.md) for configuration ownership, routing,
standby behavior, and the boundary with the realtime audio code.
