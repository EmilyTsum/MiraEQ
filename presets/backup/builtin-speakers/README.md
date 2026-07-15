# Built-in speakers — best-known settings (backup, 2026-07-15)

Snapshot of the tuned MacBook Air built-in speaker configuration. Do not delete.

To restore, copy the files back into `~/.config/MiraEQ`:

```sh
cp config.txt ~/.config/MiraEQ/config.txt
cp M5_MacBook_Air_Rich.txt ~/.config/MiraEQ/presets/device/
cp .MiraEq_BuiltInSpeakerDevice_Processing.txt ~/.config/MiraEQ/presets/addons/
```

Contents:
- `config.txt` — routing: `MacBook Air Speakers = M5_MacBook_Air_Rich.txt | .MiraEq_BuiltInSpeakerDevice_Processing.txt`
- `M5_MacBook_Air_Rich.txt` — device EQ preset
- `.MiraEq_BuiltInSpeakerDevice_Processing.txt` — per-device processing: latency Ultra (1 ms), spatial off, BassHarmonics 12% (135 Hz), LowEndGuard 45%, BassFocus 70%, BassComp 50%, SoftLimit off
