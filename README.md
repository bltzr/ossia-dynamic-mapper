# ossia-dynamic-mapper

A [QML Mapper](https://ossia.io/score-docs/devices/mapper-device.html) device for [ossia score](https://ossia.io) that replaces a Max/MSP hardware control patch for live performance with granular synthesis.

## Intent

The goal is to drive a multi-track granular synthesis score entirely from hardware MIDI controllers, without Max/MSP as a middleman. The mapper handles device discovery, MIDI routing, parameter accumulation, and feedback LEDs in a single self-contained QML file that lives inside the score document.

The design prioritises:
- **Pickup on track focus** — when you select a track, knob accumulators seed from score's current parameter values, so the first knob movement never causes a jump
- **Exponential pitch bend** — pitch accumulates while the wheel is held, holds when released, and reseeds from score on the next touch (picks up external changes from the GUI or automation)
- **Multiplicative density** — matches the original Max patch feel: proportional control at any density level, asymptotically approaches zero rather than snapping to it
- **No Max dependency** — all logic runs inside score's QML engine via `Ossia.Mapper`

## Controllers

| Device | Role |
|--------|------|
| Novation LaunchControl XL | Per-track faders, EQ knobs, track focus + mode buttons |
| Arturia MiniLab mkII | Relative encoders for granular params, keyboard pitch bend, pads for source selection |
| DS1 DS_Controls | Master mix gain (all tracks) |
| FBV Express Mk II | Recording toggle (foot pedal) |

## Parameter mapping

Each of the 8 tracks exposes:
- Granular: position, duration, density (multiplicative), position/duration/pitch jitter, window position and width
- EQ: lowshelf cutoff/gain, two bandshelf frequency/gain pairs, highshelf cutoff/gain
- Routing: inmix source selection (exclusive), recording enable, pan/front-back/left-right

## Architecture

```
MIDI in → handleXL / handleML / handleDS1 / handleFBV
        → Device.write("/encoder/…", normalizedValue)
        → createTree write callback
        → [{address: "score:/…", value: scaled}]
        → score parameter
```

Knob state is kept in `_ts[track][key]` — a per-track accumulator table normalised to `[0, 1]`. Shadow nodes on the mapper device (no `bind`) mirror the last-written value so `Device.read` can seed accumulators on track selection.

## Score file

The mapper is embedded in `jam-mapper.score`. The QML source lives in this repo (`devices-mapper.qml`) and is injected via:

```python
python3 inject.py  # see inject.py
```

## Score C++ fix

The mapper requires a one-line fix in ossia score's `MapperDevice.cpp` so that `Device.read()` can access mapper-local nodes after device reconnects. See [ossia/score#2032](https://github.com/ossia/score/pull/2032).

Without it, shadow nodes are not readable and parameter pickup silently falls back to the in-memory accumulator state.

## Dependencies

- ossia score (dev build with PR #2032 applied, or a release that includes it)
- Novation LaunchControl XL firmware in factory template mode (ch 9)
- Arturia MiniLab mkII in relative encoder mode (Offset64) for the main knobs
