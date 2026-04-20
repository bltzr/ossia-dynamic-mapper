# Analysis: Max/MSP ↔ ossia score controller bridge — two systems

Analysis date: 2026-04-17  
Files analysed:
- `/Users/bltzr/Dropbox/Prog/scores/NXL+ArturiaKalun/devicesJAM.maxpat` + `/Users/bltzr/Dropbox/Projets/Conseil/Kalun/KalunGT.score`
- `/Users/bltzr/Dropbox/Prog/scores/NXL+Arturia JAM/devicesJAM.maxpat` + `/Users/bltzr/Dropbox/Prog/scores/jam-MBP.score`

---

## Common architecture

Both pairs follow the same structural pattern:

```
Physical MIDI controllers
        │  (USB MIDI)
        ▼
Max/MSP patcher (devicesJAM.maxpat)
        │  reads MIDI events → transforms → sends via OSCQuery
        ▼
ossia score (via ossia.client + oscquery ws://127.0.0.1:9999)
        │
        ▼
Score parameters (granular synth, EQ, panning, etc.)
```

Max is doing three things:
1. **Controller input routing**: reading MIDI from multiple devices
2. **Value transformation**: scaling, relative-encoder accumulation, note-to-freq conversion
3. **Track selection / multiplexing**: routing controllers to the currently selected score interval

The goal is to replace Max entirely with an ossia Mapper device (QML).

---

## SYSTEM 1: Kalun / GameTrak

### KalunGT.score structure

- **Root interval**: `GameTrak` (scripting name, duration ≈131.8s)
- **Audio chain** inside GameTrak:
  - `gran` (granola) — granular synthesis
  - `inmix` (mono_mix) — input mixer
  - `rec` (avnd_audio_recorder) — live recording
  - `Bandshelf`, `Lowshelf`, `Highshelf` — parametric EQ
  - `qpan` (quad_pan) — 4-channel spatial panning
  - `RMS`, `Display` — monitoring
  - 6× `Mapping curve` — built-in ossia parameter mappings
  - `Pro-Q 3` (VST)
  - `Audio Merger`
  
- **score device**: OSCQuery at ws://127.0.0.1:9999

### KalunGT Max patcher

The devicesJAM.maxpat for Kalun:
- Connects to `ossia.client score` (OSCQuery)
- Reads the **Game-Trak V1.3** HID device (6 axes: `axis-1` through `axis-6`)
  - Axes 1,2 (string 1 horizontal/vertical): raw → normalized [-1,+1]
  - Axes 4,5 (string 2): same
  - Axes 3,6 (string tip pull): `/4096.` then `!- 1.` → [0,1] inverted
- Packs 6 values as `GameTrak` and sends via `s GameTrak`
- `ossia.remote score:/*/processes/s/intervals/GameTrak/processes/gran/sound/value`
  - Routes a file path (from a coll of sound files) to the granulator's sound parameter
  - Source file selection via Arturia BeatStep MIDI notes

- **Arturia BeatStep**: MIDI notes → index into sound file coll → set gran/sound
- **FBV Express Mk II Port 1**: Pedal CC → rec blink, recording triggers
- **Launch Control XL**: Note 105=stop, 106=sel, 107=reset, 108=rec modes

### Built-in GameTrak→score Mappings (in the score itself)

The score contains 6 Mapping process nodes that read directly from the GameTrak HID device:

| Mapping | Source (HID) | Target param | Source range | Target range |
|---------|-------------|-------------|-------------|-------------|
| Mapping curve | `axis-3` | `gran/density` | [-0.2, 1.0] | [30.0, 1.0] (inverted) |
| Mapping curve.1 | `axis-6` | (connected via cable) | [-0.3, 0.7] | [1.0, 0.0] |
| Mapping curve.2 | `axis-4` | `Bandshelf/frequency` ? | [-1.0, 1.0] | [200, 15000] |
| Mapping curve.4 | `axis-5` | `Bandshelf/cutoff`? | [-1.0, 1.0] | [50, 5000] |
| Mapping curve.5 | `axis-1` | (param) | [-1.0, 1.0] | [0.0, 1.0] |
| Mapping curve.6 | `axis-2` | (param) | [-1.0, 1.0] | [0.0, 1.0] |

Note: The GameTrak axes are already mapped INSIDE the score via Mapping processes — no Max needed for those. Max is mainly needed for the sound file selection, recording, and transport.

---

## SYSTEM 2: JAM — the main system to replace

### jam-MBP.score structure

```
BaseScenario (scripting name = "ECHO")   ← root
  └── Scenario (name = "s")              ← main timeline
        ├── track.1  (23.3s, looping)
        ├── track.2
        ├── track.3
        ├── track.4
        ├── track.5
        ├── track.6
        ├── track.7
        ├── track.8  (special: EQ + qpan + gain)
        ├── in3      (input quad_pan only)
        └── in4      (input quad_pan only)
```

Each `track.N` (1–7) contains (in order, chained):
1. `pretrans` — pre-transition gain stage → audio:/out/10
2. `inmix` (mono_mix) — 8-input mixer; inputs from audio:/in/1–9
3. `preamp` — pre-amplifier → audio:/out/9
4. `rec` (avnd_audio_recorder) — records to file; output → route:/track.N/rec
5. `gran` (granola) — granular synthesis; reads from route:/track.N/rec
6. `Bandshelf` (dspfilters_bandshelf)
7. `Lowshelf` (dspfilters_lowshelf)
8. `Highshelf` (dspfilters_highshelf)
9. `amp` → audio:/out/7 (or 8)
10. `trans` → audio:/out/8
11. `qpan` (quad_pan) → audio:/out/1-4

**OSCQuery address pattern**:
`score:/ECHO/processes/s/intervals/track.N/processes/PROCESS/PARAM/value`

### Controllers

#### Novation LaunchControl XL

Direct per-track controls (one knob/fader per track, all active simultaneously):

| Control | CC (track N) | Parameter | Range | Formula |
|---------|-------------|-----------|-------|---------|
| Row 1 knobs | CC 12+N (13–20) | `gran/gain` | [0, 1] | `val/64.` |
| Row 2 knobs | CC 28+N (29–36) | `qpan/f_b` | [-1, 1] | `(val/63.5)-1.` |
| Row 3 knobs | CC 48+N (49–56) | `qpan/l_r` | [-1, 1] | `(val/63.5)-1.` |
| Faders | CC 76+N (77–84) | `qpan/gain` | [0, 1] | `val/127.` |

Mode buttons (channel 9):

| Note | Function |
|------|----------|
| 105 | Transport: `ossia.remote stop` |
| 106 | Toggle selMode (LED: vel 60 when active) |
| 107 | Toggle resetMode |
| 108 | Toggle recMode |
| 41–44 | Track Focus 1–4 (Track Select) |
| 57–60 | Track Focus 5–8 |

Track Focus button LEDs: written on channel 9 using `noteout "Launch Control XL" 9`
- Active track: velocity 60 (tracks 1-4) or 62 (tracks 5-8)
- Inactive track: velocity 0 (off)

LED note numbers:
- Track N (N≤4): note = 40+N  (41,42,43,44)
- Track N (N>4): note = 52+N  (57,58,59,60)

#### Arturia MiniLab mkII (Relative mode preset)

All knobs on **channel 1**, **relative mode** (center=64, 63=−1 step, 65=+1 step).

Routes to the **currently selected track** via the `selected` global variable.

Relative encoder accumulation in Max:
```
CC → subtract 64 → divide by 256 → accumulate → clamp [0,1] → scale to [min,max] → send
```

| CC | k_set args | Parameter | Min | Max | Default |
|----|-----------|-----------|-----|-----|---------|
| 2  | k_set_lo | `gran/position` | 0 | 1 | 0 |
| 3  | k_set_lo | `gran/duration` | 0 | 1 | 1 |
| 4  | win_coefs | `gran/window coefs` | [0,0] | [1,1] | [0.5, 0.01] |
| 5  | k_set | `Lowshelf/cutoff` | 20 | 5000 | 250 |
| 6  | k_set | `Bandshelf/frequency` | 200 | 15000 | 2000 |
| 7  | k_set | `Bandshelf/bandwidth` | 0.2 | 1.8 | 1.0 |
| 8  | k_set | `Highshelf/cutoff` | 200 | 15000 | 5000 |
| 9  | density | `gran/density` | 0 | 1 | 0 |
| 1  | k_jitter | `gran/density jitter` | 0 | 1 | 0 |
| 10 | k_jitter | `gran/position jitter` | 0 | 1 | 0 |
| 11 | k_jitter | `gran/duration jitter` | 0 | 1 | 0 |
| 12 | k_jitter | `gran/pitch jitter` | 0 | 1 | 0 |
| 13 | k_set | `Lowshelf/gain` | -24 | 24 | 0 (scale /32.) |
| 14 | k_set | `Bandshelf/gain` | -24 | 24 | 0 |
| 15 | k_set | `Highshelf/slope` | 0.1 | 3.0 | 1.0 |
| 16 | k_set | `Highshelf/gain` | -24 | 24 | 0 |
| 20 | pitch_kb (abs) | `gran/pitch jitter` | 0 | 1 | — |

Keyboard notes (ch 16) → `gran/pitch/value`  
Pitch bend → `gran/pitch/value` (fine)  
CC 20 (abs) → `gran/pitch jitter/value`

#### DS1 DS_Controls

| CC | Target | Notes |
|----|--------|-------|
| 49 | `score:/ECHO/.../track.*/processes/mix/gain 1/value` | Wildcard, all tracks |

#### FBV Express Mk II Port 1

| CC | Sends to |
|----|----------|
| 1  | `s pedalRec` (recording pedal) |
| 2  | `s pedalRec` (recording pedal) |

### Track selection mechanism (button_sel.maxpat — KEY LOGIC)

`button_sel` is instantiated once per track (arguments: track number 1–8).

**Logic trace:**
```
loadmess #N →
  → / 5 → sel 0 1:
        0 (tracks 1–4) → note_offset = 40
        1 (tracks 5–8) → note_offset = 52
  → note_offset + #N = target_note  (e.g., track 3 → 40+3 = 43)

notein "Launch Control XL" → [pitch, velocity, channel]
  pitch → compare with target_note
  velocity → compare with 127 (note-on test)

  IF pitch == target_note AND velocity == 127:
    → s selected (#N)         ← broadcast: "track N is now selected"
    → s selfill (#N)          ← broadcast: update LEDs

  When "selected" changes:
    → compare selected == #N
    → toggle state → LED feedback (noteout target_note, vel 60/62/0)

  selMode=1: multi-select (toggle per track)
  selMode=0: exclusive select (one track at a time)
```

**What "selected" controls:**  
All `k_set`, `k_set_lo`, `k_jitter`, `density`, `pitch_kb`, `win_coefs`, `source_select`
abstractions listen to `r selected`. They gate their output through `route #N` — only the
instance whose track number matches the current `selected` value passes the controller data.

### source_select.maxpat

Listens to Arturia MiniLab mkII pad notes (notes 36–43, ch 9?):
- Pad note → modulo 4 → select one of 4 input gain channels of `inmix`
- Sets the chosen `inmix/gain N/value` to 1.0, all others to 0.0
- Exclusive switching (one audio source active at a time)
- Sends SysEx to MiniLab to light up the selected pad LED

### p recs sub-patcher (recording management)

- Maintains a `coll recs` of recorded file paths per track
- When recMode active + selMode + track selection: starts/stops recording on selected tracks
- Routes the recorded file path back to `gran/sound/value` to read back what was just recorded
- Foot pedal (FBV) triggers recording in parallel

---

## What Max is doing that ossia cannot currently do natively

1. **Relative encoder accumulation** — integrating delta CC values into absolute position
   → Can be done in QML Mapper's `read` function using closure variables

2. **LED feedback** — writing MIDI notes back to LaunchControl XL for button illumination
   → Can be done by returning `{address, value}` pairs pointing to MIDI output addresses

3. **Track selection state** — routing all MiniLab knobs to whichever track is selected
   → Requires mutable JS state in QML Mapper closure; all knobs check `selectedTrack` before
   building the target address

4. **Multi-select** — the `coll selecteds` allows controlling several tracks simultaneously
   → Implementable in QML with a JS array/object for selected track set

5. **Source selection** — exclusive input source switching + SysEx LED feedback
   → Can be done in QML with an array of addresses to zero out + one to set to 1.0

6. **Recording management** (coll recs, file routing) — complex state machine
   → Partially doable in QML, but the SysEx LED feedback and full state machine is complex

7. **OSCQuery reconnection logic** — the `p utils` subpatcher with `del 1000` + `connect`
   → Not needed: the ossia QML Mapper device handles the connection itself

---

## Key differences between the two systems

| Aspect | Kalun/GameTrak | JAM (NXL+Arturia) |
|--------|---------------|-------------------|
| Score structure | Single deep interval (GameTrak) | 8 parallel looping intervals (track.N) |
| GameTrak | HID device, 6 axes | Not used |
| Selection | Not used | 8-way track selection via LaunchControl XL |
| Granular synthesis | Mapped from GameTrak | Controlled via MiniLab (selected track) |
| Audio input | Fixed | Selectable via MiniLab pads (source_select) |
| Recording | Manual via BeatStep/pedal | Automated + pedal controlled |
| Mappings in score | Yes (6 Mapping processes in score) | Partly (no built-in mappings) |

---

## Recommended implementation strategy for QML Mapper (JAM system)

See `devicesJAM-mapper.qml` in this folder for the implementation.

Key design decisions:
1. Maintain all state in JS closure variables inside `createTree()`
2. One Mapper node per physical controller input (MIDI CC or note)
3. Track selection nodes return arrays of LED actions + set JS `selectedTracks` state
4. All MiniLab knob nodes check `getSelected()` to get the target track list
5. LaunchControl XL fader/knob nodes are direct 1:1 maps (no selection needed)
6. Source selection implemented as exclusive gain switching

Unknowns to verify by testing:
- Exact MIDI channel for LaunchControl XL Track Focus buttons (assumed: ch 9)
- Exact MIDI channel for MiniLab knobs (assumed: ch 1 from preset analysis)
- Whether ossia Mapper `read` can return `null`/`[]` for "no action"
- Whether ossia exposes MIDI note-on as writable (for LED feedback)
- Exact ossia address format: `Device:/channel/note/N` vs `Device:/channel/note_on/N`
