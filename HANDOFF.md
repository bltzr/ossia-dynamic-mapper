# jam-mapper handoff — 2026-04-20

## Context
`jam-mapper.score` is a live performance score in ossia score.
It uses a QML Mapper device (`devices-mapper.qml`) to bridge four MIDI controllers
to 8 Granola granular-synthesis tracks.

Hardware: Launch Control XL · Arturia MiniLab mkII · DS1 DS_Controls · FBV Express Mk II

## What was done this session

### 1. Granola MIDI inlet — channel filter (`score-avnd-granola`)
**File:** `Granola/GranolaModel.cpp`

Added a status-byte filter to skip non-note MIDI messages:
```cpp
const uint8_t status = msg.bytes[0] & 0xF0;
if(status != 0x90 && status != 0x80)
    continue;
```
This prevents pad CCs and other non-note messages from interfering with
Granola's MIDI voice tracking.

### 2. Granola MIDI inlet address — channel 16 only (`jam-mapper.score`)
All 7 Granola MIDI inlets (id=26, uuid `c18adc77-e0e0-4ddf-a46c-43cb0719a890`)
changed from `Arturia MiniLab mkII:/` (all channels) to `Arturia MiniLab mkII:/16`.

**Why:** The MiniLab sends pads on ch 9/10 and keyboard on ch 16. Subscribing to
root (`/`) caused pad NoteOns/CCs to reach Granola's MIDI bus and corrupt voice
state. The `/16` filter in `pull_visitors.hpp` (`global_pull_node_visitor`) routes
only keyboard messages to Granola, at the ossia execution level — no QML involvement.

The MiniLab device in the score has `CreateWholeTree:false` but already has a `/16`
child node serialised in its Children array, so the address resolves correctly.

### 3. QML Mapper — pad handler rewrite (`devices-mapper.qml`)
**Pad behaviour:** MiniLab pads use "switched CC" mode — they send CC ch 10 (0-based 9),
CC numbers 40-47, value 127 on first press (ON) and 0 on second press (OFF).
No NoteOn/NoteOff involved.

Old code incorrectly:
- Checked notes 36-43 AND CCs 36-43 (wrong range)
- Toggled `_padState` in software (double-toggle: needed 2 presses)
- Guarded on `d2 > 0`, ignoring the OFF message

New code:
```js
var isPadCC = st === 0xB0 && ch === 9 && d1 >= 40 && d1 <= 47;
if (isPadCC) {
    var padIdx = d1 - 40;
    _padState[padIdx] = (d2 > 0);   // mirror hardware state directly
    miniLabPadLED(padIdx, _padState[padIdx]);
    Device.write("/src_sel", padIdx * 2 + (_padState[padIdx] ? 1 : 0));
    return;
}
```

### 4. QML Mapper — keyboard note forwarding removed
A broken `Device.write(sa(..., "gran", "midi in"), [...])` block was removed.
`Device.write` cannot push to a MIDI bus inlet. Keyboard notes reach Granola
via the ossia MIDI address subscription (`/16`) — no QML forwarding needed.

### 5. `devicesJAM-mapper.qml` — reference file updated
The old reference mapper (`devicesJAM-mapper.qml`) had `src_sel_0`…`src_sel_7`
with bind addresses `Arturia MiniLab mkII In:/9/on/36`…`/9/on/43`.
Updated to `:/10/control/40`…`:/10/control/47` to match the new CC assignment.

## Architecture note: QML vs ossia MIDI routing

The Mapper device opens its **own** libremidi connection to the MiniLab (via
`Protocols.inboundMIDI`). The ossia MIDI device `Arturia MiniLab mkII` in the
score's device list opens a **separate** connection. Both receive all MIDI
independently. The QML `handleML` returning early does NOT prevent messages from
reaching any ossia address subscriber — they are completely independent paths.

## What is NOT yet resolved

### The root MIDI routing bug
Pad CC releases (`0xBx ch 10`) caused ALL Granola instances to lose MIDI
simultaneously, even those behind a MIDI filter process. Investigation traced
the path to `execution_state::get_new_values()` → `global_pull_node_visitor`
in `pull_visitors.hpp`, but no crash or corruption was found in `midi_protocol.cpp`.

The workaround (subscribing to `/16` instead of `/`) prevents pad messages from
ever reaching Granola's MIDI bus, making the root cause moot for now — but the
underlying bug (global MIDI break from a pad CC) was never explained.

### MiniLab pad LED feedback
`miniLabPadLED(padIdx, on)` sends SysEx `F0 00 20 6B 7F 42 02 00 10 <padIdx> <1|0> 00 00 F7`.
It is called on pad press/release. Verify that `padIdx` (0-7) is the correct byte
for the MiniLab mkII LED SysEx (vs. the CC number 40-47). If LEDs don't light,
try passing `d1` (the CC number) instead of `padIdx`.

### `devicesJAM-mapper.qml` LED out addresses
In `src_sel_0`…`src_sel_7`, the LED feedback still uses:
```js
for (var p = 40; p <= 47; p++)
    acts.push({ address: "Arturia MiniLab mkII Out:/9/on/"+p, value: p===44?127:0 });
```
The individual `p===N` checks are off by 4 (should be `p===40` for src_sel_0, not
`p===44`). This file is the old reference and is not currently loaded by the score,
but fix if it gets used again.

## Key files

| File | Repo | Notes |
|------|------|-------|
| `devices-mapper.qml` | `AI-score-mappers` | active mapper, embedded in score |
| `devicesJAM-mapper.qml` | `AI-score-mappers` | old reference, not loaded |
| `jam-mapper.score` | `~/Dropbox/Prog/scores` | main score, not in git |
| `Granola/GranolaModel.cpp` | `score-avnd-granola` | MIDI status filter added |
| `Granola/GranolaModel.hpp` | `score-avnd-granola` | unchanged |

## Dev workflow
- Build: `cd /Users/bltzr/dev/score/build && cmake --build . --target score_addon_granola -j8`
- Launch: `/Users/bltzr/dev/score/build/score /Users/bltzr/Dropbox/Prog/scores/jam-mapper.score`
- Inject QML changes into score: run the Python reinject snippet (updates `"Text"` field in score JSON)
- **Never commit/push until user has tested and confirmed**
