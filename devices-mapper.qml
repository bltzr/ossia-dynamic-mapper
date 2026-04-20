// devices-mapper.qml  v3
// Replaces NXL+Arturia JAM/devicesJAM.maxpat for jam-mapper.score.
//
// Architecture (inspired by ossia_midi_controller_map_spec_v2):
//   Protocols.inboundMIDI / outboundMIDI  →  raw byte handlers
//   →  Device.write("/node/path", value)
//   →  createTree node write()  →  [{address:"score:/…", value}]
//
// Tree layout (mirrors spec §7-9 Node/Bank conventions):
//   /status/{xl_in, xl_out, ml_in, ml_out, ds1_in, fbv_in}
//   /mode/{track_sel, sel, rec, reset}
//   /transport/{play, stop}
//   /strip/{1-8}/{fader, gain, f_b, l_r}          ← XL absolute, per-track
//   /encoder/{pos, dur, density, dens_jit,          ← MiniLab relative, selection-routed
//             pos_jit, dur_jit, pitch_jit,
//             win_coefs, pitch_jit_abs,
//             ls_cutoff, ls_gain,
//             bs_freq, bs_bw, bs_gain,
//             hs_cutoff, hs_slope, hs_gain}
//   /keyboard/{pitch, bend}                        ← MiniLab keyboard
//   /src_sel                                        ← MiniLab pads → inmix source
//   /ds1/mix_gain                                  ← DS1 CC49 all-track master
//   /pedal/rec                                      ← FBV foot pedal toggle
//
// Controllers:
//   Novation LaunchControl XL  in+out  (ch 9)
//   Arturia MiniLab mkII       in+out  (knobs ch 1, keyboard ch 16, pads ch 9)
//   DS1 DS_Controls            in      (CC49 ch 1)
//   FBV Express Mk II Port 1   in      (CC1/CC2 ch 1)
//
// Encoder mode (spec §10 Encoder.Offset64 equivalent):
//   MiniLab relative knobs: centre=64, >64 CW, <64 CCW.
//   Accumulated in _ts[track][key] ∈ [0,1], sensitivity = 1/256 per tick.
//   Gain/EQ params use divisor 32 (coarser, matching original pitch_kb.maxpat).
//
// SysEx pad LED feedback (spec §12 ColorFeedback equivalent):
//   Arturia MiniLab mkII proprietary SysEx:
//     F0 00 20 6B 7F 42 02 00 10 <pad 0-7> <1|0> 00 00 F7
//   Sent via mlOut.sendMessage([...]) in handleML().
//
// Init sequence (spec §6 pattern):
//   xlOut onOpen: all Track Focus + mode button LEDs off.
//   mlOut onOpen: all pad LEDs off.

import Ossia 1.0 as Ossia

Ossia.Mapper {
    id: root

    // =========================================================================
    // STATE
    // =========================================================================

    // Root interval scripting name in the score document.
    // Change this to match your score file's root interval name.
    property string scoreRoot: "jam-MBP-mapper2"

    // Track selection array (0-based internally, 1-based externally).
    // spec §4 user-defined property — reactive state.
    property var _sel:     [true,false,false,false,false,false,false,false]
    property bool _selMode:   false
    property bool _recMode:   false
    property bool _resetMode: false

    // Pitch bend accumulator — timer reads _pitchNorm every 50 ms and drifts
    // _pitchAccum while wheel is held off-centre.  When wheel returns to centre
    // (|norm| < 0.02), accumulation stops and pitch holds its current value.
    property real _pitchAccum: 0.0
    property real _pitchNorm:  0.0   // updated on every bend message; read by interval timer
    property bool _pitchCentered: true  // true while wheel is at rest; triggers reseed on next touch

    property bool _initDone: false  // true once startup timer has seeded all tracks

    // Per-track recording state (toggled by XL lower row buttons)
    property var _recState: [false,false,false,false,false,false,false,false]

    // Per-track encoder accumulators for MiniLab relative knobs.
    // Spec §10: encoder accumulation normally done in C++ (Encoder.Offset64).
    // Here we implement it in QML as the Protocols API receives raw bytes.
    property var _ts: (function() {
        var t = {};
        for (var i = 1; i <= 8; i++) t[i] = {
            pos:      0.0,   dur:      1.0,   density:  0.3,
            densJit:  0.0,   posJit:   0.0,   durJit:   0.0,
            pitchJit: 0.0,   winPos:   0.5,   winWidth: 0.05,
            lsCutoff: 0.048, lsGain:   0.5,   bsFreq:   0.12,
            bsGain:   0.5,   bs1Freq:  0.5,   bs1Gain:  0.5,
            hsCutoff: 0.33,  hsGain:   0.5
        };
        return t;
    }())

    // =========================================================================
    // HELPERS
    // =========================================================================

    // Score address for track N / process / parameter.
    function sa(t, proc, param) {
        return "score:/" + scoreRoot + "/processes/s/intervals/track."
               + t + "/processes/" + proc + "/" + param + "/value";
    }

    // Array of currently selected track numbers (1-based).  Default: [1].
    function getSelected() {
        var r = [];
        for (var t = 1; t <= 8; t++) if (_sel[t-1]) r.push(t);
        return r.length > 0 ? r : [1];
    }

    function clamp01(x) { return x < 0.0 ? 0.0 : x > 1.0 ? 1.0 : x; }
    function scale(v, mn, mx) { return mn + v * (mx - mn); }

    // Seed _ts[t] from the current score state.
    // Primary:  Device.read(score address) — works after C++ fix that keeps the
    //           mapper device in device_obj->devices across rootsChanged resets.
    // Fallback: /shadow/tN/key — mapper nodes updated by encoder write callbacks,
    //           so they hold the last value written this session (normalized [0,1]).
    function initTrackFromScore(t) {
        var params = [
            ["pos",      "gran",        "position",          0,    1    ],
            ["dur",      "gran",        "duration",          0,    1    ],
            ["density",  "gran",        "density",           0,    256  ],
            ["densJit",  "gran",        "density jitter",    0,    1    ],
            ["posJit",   "gran",        "position jitter",   0,    1    ],
            ["durJit",   "gran",        "duration jitter",   0,    1    ],
            ["pitchJit", "gran",        "pitch jitter",      0,    1    ],
            ["lsCutoff", "Lowshelf",    "cutoff",            20,   5000 ],
            ["lsGain",   "Lowshelf",    "gain",              -24,  24   ],
            ["bsFreq",   "Bandshelf",   "frequency",         200,  15000],
            ["bsGain",   "Bandshelf",   "gain",              -24,  24   ],
            ["bs1Freq",  "Bandshelf.1", "frequency",         20,   20000],
            ["bs1Gain",  "Bandshelf.1", "gain",              -24,  24   ],
            ["hsCutoff", "Highshelf",   "cutoff",            200,  15000],
            ["hsGain",   "Highshelf",   "gain",              -24,  24   ]
        ];
        for (var i = 0; i < params.length; i++) {
            var p   = params[i];
            var raw = Device.read(sa(t, p[1], p[2]));         // try score directly
            if (raw !== null && raw !== undefined) {
                _ts[t][p[0]] = clamp01((raw - p[3]) / (p[4] - p[3]));
            } else {
                raw = Device.read("/shadow/t" + t + "/" + p[0]); // fallback: shadow
                if (raw !== null && raw !== undefined)
                    _ts[t][p[0]] = clamp01(raw);
            }
        }
        // window coefs — score returns [winPos, winWidth] as a list
        var wraw = Device.read(sa(t, "gran", "window coefs"));
        if (wraw !== null && wraw !== undefined && wraw[0] !== undefined) {
            _ts[t].winPos   = clamp01(wraw[0]);
            _ts[t].winWidth = clamp01(wraw[1]);
        } else {
            var wpraw = Device.read("/shadow/t" + t + "/winPos");
            var wwraw = Device.read("/shadow/t" + t + "/winWidth");
            if (wpraw !== null && wpraw !== undefined) _ts[t].winPos   = clamp01(wpraw);
            if (wwraw !== null && wwraw !== undefined) _ts[t].winWidth = clamp01(wwraw);
        }
    }

    // Relative encoder accumulation — spec §10 Encoder.Offset64 in QML.
    // rawCC: 0-127, centre=64; divisor controls sensitivity.
    function accum(cur, rawCC, divisor) {
        return clamp01(cur + (rawCC - 64) / (divisor || 256.0));
    }

    // LaunchControl XL Track Focus button note number for track n (1-based).
    // Tracks 1-4: notes 41-44;  tracks 5-8: notes 57-60.
    function xlLedNote(n) { return n <= 4 ? 40 + n : 52 + n; }

    // XL lower row (record arm) note number for track n (1-based).
    // Tracks 1-4: notes 73-76;  tracks 5-8: notes 89-92.
    function recLedNote(n) { return n <= 4 ? 72 + n : 84 + n; }

    // Toggle recording for track n and update LED.
    function toggleRec(n) {
        _recState[n-1] = !_recState[n-1];
        _recState = _recState;
        Device.write("/rec/" + n, _recState[n-1]);
        if (xlOut) xlOut.sendNoteOn(9, recLedNote(n), _recState[n-1] ? 63 : 0);
    }

    // Refresh all 8 rec LEDs from _recState.
    function sendXLRecLEDs() {
        if (!xlOut) return;
        for (var t = 1; t <= 8; t++)
            xlOut.sendNoteOn(9, recLedNote(t), _recState[t-1] ? 63 : 0);
    }

    // Spec §12.1 LedFeedback equivalent: refresh all 8 Track Focus LEDs.
    function sendXLTrackLEDs() {
        if (!xlOut) return;
        var onVel = _selMode ? 60 : 62;
        for (var t = 1; t <= 8; t++)
            xlOut.sendNoteOn(9, xlLedNote(t), _sel[t-1] ? onVel : 0);
    }

    // Select / toggle a track and refresh LEDs.
    // Re-reads current score values into _ts[n] so knob accumulators start
    // from wherever the parameter actually is, not from a stale cached value.
    function selectTrack(n) {
        if (_selMode) {
            _sel[n-1] = !_sel[n-1];
        } else {
            for (var t = 0; t < 8; t++) _sel[t] = false;
            _sel[n-1] = true;
        }
        _sel = _sel;
        sendXLTrackLEDs();            // LEDs first — before any potentially slow reads
        Device.write("/mode/track_sel", n);
        // Open Granola's MIDI gate only on selected track(s), close all others
        for (var t = 1; t <= 8; t++)
            Device.write("/midi_gate/" + t, _sel[t-1]);
        if (_selMode) {
            if (_sel[n-1]) initTrackFromScore(n);
        } else {
            initTrackFromScore(n);
        }
    }

    // Reset all MiniLab accumulators for track n to defaults.
    // Clears _initialized[n] so the next knob touch re-reads from score.
    function resetTrack(n) {
        _ts[n] = { pos:0.0, dur:1.0, density:0.3, densJit:0.0, posJit:0.0,
                   durJit:0.0, pitchJit:0.0, winPos:0.5, winWidth:0.05,
                   lsCutoff:0.048, lsGain:0.5, bsFreq:0.12,
                   bsGain:0.5, bs1Freq:0.5, bs1Gain:0.5,
                   hsCutoff:0.33, hsGain:0.5 };
    }

    // Spec §12.4 ColorFeedback equivalent: Arturia MiniLab mkII pad LED SysEx.
    //   F0 00 20 6B 7F 42 02 00 10 <pad 0-7> <1=on|0=off> 00 00 F7
    function miniLabPadLED(padIdx, on) {
        if (mlOut)
            mlOut.sendMessage([0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42,
                               0x02, 0x00, 0x10, padIdx, on ? 1 : 0,
                               0x00, 0x00, 0xF7]);
    }

    // Name-based device lookup (used instead of spec §5 EndpointFilter
    // because manufacturer SysEx IDs for these devices are not verified).
    function findMIDI(devices, fragment) {
        for (var i = 0; i < devices.length; i++)
            if (JSON.stringify(devices[i]).indexOf(fragment) >= 0)
                return devices[i];
        return null;
    }

    // =========================================================================
    // DEVICE DISCOVERY  (spec §5 EndpointFilter equivalent — name-based)
    // =========================================================================

    property var _allIn:  Protocols.inboundMIDIDevices()
    property var _allOut: Protocols.outboundMIDIDevices()

    // =========================================================================
    // CONNECTIONS  (spec §20 Multi-Endpoint equivalent)
    // =========================================================================

    // Launch Control XL — input (ch 9)
    property var xlIn: (function() {
        var dev = findMIDI(_allIn, "Launch Control XL");
        if (!dev) return null;
        return Protocols.inboundMIDI({
            Transport: dev,
            onOpen:    function(s) { Device.write("/status/xl_in", "open"); },
            onClose:   function()  { Device.write("/status/xl_in", "closed"); },
            onError:   function(e) { Device.write("/status/xl_in", "error:" + e); },
            onMessage: function(msg) { root.handleXL(msg); }
        });
    }())

    // Launch Control XL — output (Track Focus + mode button LED feedback)
    // Spec §6 init equivalent: all LEDs off on connect.
    property var xlOut: (function() {
        var dev = findMIDI(_allOut, "Launch Control XL");
        if (!dev) return null;
        return Protocols.outboundMIDI({
            Transport: dev,
            onOpen: function(s) {
                Device.write("/status/xl_out", "open");
                for (var t = 1; t <= 8; t++) s.sendNoteOn(9, xlLedNote(t), 0);
                for (var t = 1; t <= 8; t++) s.sendNoteOn(9, recLedNote(t), 0);
                s.sendNoteOn(9, 106, 0);
                s.sendNoteOn(9, 107, 0);
                s.sendNoteOn(9, 108, 0);
            },
            onClose: function()  { Device.write("/status/xl_out", "closed"); },
            onError: function(e) { Device.write("/status/xl_out", "error:" + e); }
        });
    }())

    // Arturia MiniLab mkII — input
    property var mlIn: (function() {
        var dev = findMIDI(_allIn, "Arturia MiniLab");
        if (!dev) return null;
        return Protocols.inboundMIDI({
            Transport: dev,
            onOpen:    function(s) { Device.write("/status/ml_in",  "open"); },
            onClose:   function()  { Device.write("/status/ml_in",  "closed"); },
            onError:   function(e) { Device.write("/status/ml_in",  "error:" + e); },
            onMessage: function(msg) { root.handleML(msg); }
        });
    }())

    // Arturia MiniLab mkII — output (SysEx pad LED feedback)
    // Spec §6 init equivalent: all pad LEDs off on connect.
    property var mlOut: (function() {
        var dev = findMIDI(_allOut, "Arturia MiniLab");
        if (!dev) return null;
        return Protocols.outboundMIDI({
            Transport: dev,
            onOpen: function(s) {
                Device.write("/status/ml_out", "open");
                for (var p = 0; p < 8; p++)
                    s.sendMessage([0xF0,0x00,0x20,0x6B,0x7F,0x42,0x02,0x00,0x10,p,0,0x00,0x00,0xF7]);
            },
            onClose: function()  { Device.write("/status/ml_out", "closed"); },
            onError: function(e) { Device.write("/status/ml_out", "error:" + e); }
        });
    }())

    // DS1 DS_Controls — input
    property var ds1In: (function() {
        var dev = findMIDI(_allIn, "DS1");
        if (!dev) return null;
        return Protocols.inboundMIDI({
            Transport: dev,
            onOpen:    function(s) { Device.write("/status/ds1_in", "open"); },
            onClose:   function()  { Device.write("/status/ds1_in", "closed"); },
            onError:   function(e) { Device.write("/status/ds1_in", "error:" + e); },
            onMessage: function(msg) { root.handleDS1(msg); }
        });
    }())

    // FBV Express Mk II Port 1 — input
    property var fbvIn: (function() {
        var dev = findMIDI(_allIn, "FBV");
        if (!dev) return null;
        return Protocols.inboundMIDI({
            Transport: dev,
            onOpen:    function(s) { Device.write("/status/fbv_in", "open"); },
            onClose:   function()  { Device.write("/status/fbv_in", "closed"); },
            onError:   function(e) { Device.write("/status/fbv_in", "error:" + e); },
            onMessage: function(msg) { root.handleFBV(msg); }
        });
    }())

    // =========================================================================
    // MESSAGE HANDLERS  (spec §16 Script.onUnhandledUmp equivalent)
    // =========================================================================

    // Launch Control XL — all controls on a single MIDI channel (factory: ch 9).
    // No channel filter — we hold exclusive port access, so all messages are XL.
    // CCs: Row1 knobs 13-20, Row2 knobs 29-36, Row3 knobs 49-56, Faders 77-84.
    // Notes: Track Focus 41-44 / 57-60, transport 104-105, modes 106-108.
    function handleXL(msg) {
        if (!msg || !msg.bytes || msg.bytes.length < 2) return;
        var st = msg.bytes[0] & 0xF0;
        var ch = (msg.bytes[0] & 0x0F) + 1;
        var d1 = msg.bytes[1];
        var d2 = msg.bytes.length > 2 ? msg.bytes[2] : 0;

        if (st === 0xB0) {
            if (d1 >= 13 && d1 <= 20) {
                Device.write("/strip/" + (d1-12) + "/gain",       d2 / 64.0);  return;
            }
            if (d1 >= 29 && d1 <= 36) {
                Device.write("/strip/" + (d1-28) + "/front_back", (d2/63.5)-1.0); return;
            }
            if (d1 >= 49 && d1 <= 56) {
                Device.write("/strip/" + (d1-48) + "/left_right", (d2/63.5)-1.0); return;
            }
            if (d1 >= 77 && d1 <= 84) {
                Device.write("/strip/" + (d1-76) + "/fader",      d2 / 127.0);  return;
            }
        }

        // Note On, velocity 127 = button press (spec §10 toggle/impulse patterns).
        if (st === 0x90 && d2 === 127) {
            if (d1 >= 41 && d1 <= 44) { selectTrack(d1-40); return; }
            if (d1 >= 57 && d1 <= 60) { selectTrack(d1-52); return; }

            // Lower row record arm: tracks 1-4 = notes 73-76, tracks 5-8 = notes 89-92
            if (d1 >= 73 && d1 <= 76) { toggleRec(d1-72); return; }
            if (d1 >= 89 && d1 <= 92) { toggleRec(d1-84); return; }

            if (d1 === 104) { Device.write("/transport/play", true); return; }
            if (d1 === 105) { Device.write("/transport/stop", true); return; }

            // Mode buttons — spec §10 toggle: true equivalent.
            if (d1 === 106) {
                _selMode = !_selMode;
                if (!_selMode) {
                    var first = -1;
                    for (var fi = 0; fi < 8; fi++) {
                        if (_sel[fi]) { if (first < 0) first = fi; else _sel[fi] = false; }
                    }
                    if (first < 0) _sel[0] = true;
                    _sel = _sel;
                }
                if (xlOut) xlOut.sendNoteOn(9, 106, _selMode ? 60 : 0);
                sendXLTrackLEDs();
                Device.write("/mode/sel", _selMode);
                return;
            }
            if (d1 === 107) {
                _resetMode = !_resetMode;
                if (_resetMode) {
                    var sel = getSelected();
                    for (var i = 0; i < sel.length; i++) resetTrack(sel[i]);
                }
                if (xlOut) xlOut.sendNoteOn(9, 107, _resetMode ? 60 : 0);
                Device.write("/mode/reset", _resetMode);
                return;
            }
            if (d1 === 108) {
                _recMode = !_recMode;
                if (xlOut) xlOut.sendNoteOn(9, 108, _recMode ? 60 : 0);
                Device.write("/mode/rec", _recMode);
                return;
            }
        }
    }

    // Arturia MiniLab mkII — three channel zones:
    //   Knobs: ch 1 (0-based 0), relative Offset64 mode.
    //   Keyboard: ch 16 (0-based 15).
    //   Pads: ch 9 (0-based 8), notes 36-43.
    function handleML(msg) {
        if (!msg || !msg.bytes || msg.bytes.length < 2) return;
        var st = msg.bytes[0] & 0xF0;
        var ch = msg.bytes[0] & 0x0F;
        var d1 = msg.bytes[1];
        var d2 = msg.bytes.length > 2 ? msg.bytes[2] : 0;

        // ── Relative knobs (ch 1 = 0-based 0) ──────────────────────────────
        // Spec §10 Encoder.Offset64 + sensitivity 1/256 (1/32 for gain params).
        if (st === 0xB0 && ch === 15) {
            var sel = getSelected();
            var ft  = sel[0];   // representative track for Device.write display value

            // CC → {stateKey, devicePath, divisor, mul?}
            // mul:true uses multiplicative accumulation: new = cur * (1 + offset/div)
            // matching Max's density.maxpat behaviour (/ 127. → * cur → + cur).
            // Floor for density: 1/256 (one grain) — prevents going to zero.
            var ccInfo = {
                 1: {k:"densJit",  p:"/encoder/dens_jit",     div:256},
                 2: {k:"posJit",   p:"/encoder/pos_jit",      div:256},
                 3: {k:"durJit",   p:"/encoder/dur_jit",      div:256},
                 4: {k:"winWidth", p:"/encoder/win_coefs",    div:256},
                 5: {k:"lsCutoff", p:"/encoder/ls_cutoff",    div:4980},
                 6: {k:"bsFreq",   p:"/encoder/bs_freq",      div:2960},
                 7: {k:"bs1Freq",  p:"/encoder/bs1_freq",     div:3996},
                 8: {k:"hsCutoff", p:"/encoder/hs_cutoff",    div:2960},
                 9: {k:"density",  p:"/encoder/density",      div:127,  mul:true},
                10: {k:"pos",      p:"/encoder/pos",          div:256},
                11: {k:"dur",      p:"/encoder/dur",          div:256},
                12: {k:"winPos",   p:"/encoder/win_coefs",    div:256},
                13: {k:"lsGain",   p:"/encoder/ls_gain",      div:1536},
                14: {k:"bsGain",   p:"/encoder/bs_gain",      div:1536},
                15: {k:"bs1Gain",  p:"/encoder/bs1_gain",     div:1536},
                16: {k:"hsGain",   p:"/encoder/hs_gain",      div:1536}
            };

            if (ccInfo[d1]) {
                var info = ccInfo[d1];
                var offset = d2 - 64;
                for (var i = 0; i < sel.length; i++) {
                    if (info.mul) {
                        var factor = 1.0 + offset / info.div;
                        _ts[sel[i]][info.k] = Math.min(1.0, _ts[sel[i]][info.k] * factor);
                    } else {
                        _ts[sel[i]][info.k] = accum(_ts[sel[i]][info.k], d2, info.div);
                    }
                }
                Device.write(info.p, _ts[ft][info.k]);
                return;
            }

            // CC 20 — gran/pitch jitter absolute (not relative)
            if (d1 === 20) {
                Device.write("/encoder/pitch_jit_abs", d2 / 127.0);
                return;
            }
        }

        // ── Pitch bend (ch 1 = 0-based 0) ──────────────────────────────────
        // Accumulates pitch while wheel is held; holds when released (centre = no-op).
        if (st === 0xE0 && ch === 15) {
            var raw = (d2 << 7) | d1;
            _pitchNorm = (raw - 8192) / 8192.0;
            return;
        }

        // ── Pads — note-on (some presets) or CC (factory preset, ch 10 = 0-based 9) ──
        // Max source_select.maxpat uses ctlin ch 10 (1-based) = 0-based 9, CC 36-43.
        var padSt = (st === 0x90 && ch === 8 && d1 >= 36 && d1 <= 43 && d2 > 0)
                 || (st === 0xB0 && ch === 9 && d1 >= 36 && d1 <= 43 && d2 > 0);
        if (padSt) {
            var padIdx = d1 - 36;
            for (var p = 0; p < 8; p++) miniLabPadLED(p, p === padIdx);
            Device.write("/src_sel", padIdx);
            return;
        }
    }

    // DS1 DS_Controls — CC49 → master mix gain [0, 2] for all tracks.
    function handleDS1(msg) {
        if (!msg || !msg.bytes || msg.bytes.length < 3) return;
        if ((msg.bytes[0] & 0xF0) === 0xB0 && msg.bytes[1] === 49)
            Device.write("/ds1/mix_gain", msg.bytes[2] / 64.0);
    }

    // FBV Express Mk II — CC1 and CC2 trigger recording on selected tracks.
    function handleFBV(msg) {
        if (!msg || !msg.bytes || msg.bytes.length < 3) return;
        var cc = msg.bytes[1];
        if ((msg.bytes[0] & 0xF0) === 0xB0 && (cc === 1 || cc === 2))
            Device.write("/pedal/rec", msg.bytes[2] / 127.0);
    }

    // =========================================================================
    // TREE  (spec §7-9 Node/Bank structure implemented as JS children arrays)
    // =========================================================================

    function createTree() {

        // Local copies of root helpers captured by closure — ensures C++-stored
        // QJSValue write callbacks can always resolve these without relying on
        // the QML component scope chain from within C++ call contexts.
        var _root  = root;
        var _sa = function(t, proc, param) {
            return "score:/" + _root.scoreRoot + "/processes/s/intervals/track."
                   + t + "/processes/" + proc + "/" + param + "/value";
        };
        var _scale = function(v, mn, mx) { return mn + v * (mx - mn); };

        // ── Per-track strip helpers ───────────────────────────────────────────
        // Spec §9 Bank{count:8} equivalent: IIFE loop captures correct t.

        function makeStrip(t) {
            return {
                name: String(t),
                children: [
                    // XL fader → qpan/gain [0,1]
                    {
                        name: "fader", type: Ossia.Type.Float, value: 0.0,
                        write: function(v) {
                            return [{ address: _sa(t,"qpan","gain"), value: v.value }];
                        }
                    },
                    // XL row-1 knob → gran/gain [0,2]
                    {
                        name: "gain", type: Ossia.Type.Float, value: 0.0,
                        write: function(v) {
                            return [{ address: _sa(t,"gran","gain"), value: v.value }];
                        }
                    },
                    // XL row-2 knob → qpan/f_b [-1,1]
                    {
                        name: "front_back", type: Ossia.Type.Float, value: 0.0,
                        write: function(v) {
                            return [{ address: _sa(t,"qpan","f_b"), value: v.value }];
                        }
                    },
                    // XL row-3 knob → qpan/l_r [-1,1]
                    {
                        name: "left_right", type: Ossia.Type.Float, value: 0.0,
                        write: function(v) {
                            return [{ address: _sa(t,"qpan","l_r"), value: v.value }];
                        }
                    }
                ]
            };
        }

        var strips = [];
        for (var t = 1; t <= 8; t++) strips.push((function(n){ return makeStrip(n); })(t));

        // ── Relative encoder helper ───────────────────────────────────────────
        // Routes accumulated state from _ts[track][key] to all selected tracks.
        // Spec §10 read/write transform equivalent (applied after C++ accumulation).

        function makeEnc(name, key, min, max, proc, param) {
            return {
                name: name, type: Ossia.Type.Float, value: 0.0,
                write: function(v) {
                    var sel = _root.getSelected(), acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        var tr = sel[i];
                        acts.push({ address: _sa(tr, proc, param),
                                    value:   _scale(_root._ts[tr][key], min, max) });
                        // Keep shadow node current so initTrackFromScore fallback works
                        Device.write("/shadow/t" + tr + "/" + key, _root._ts[tr][key]);
                    }
                    return acts;
                }
            };
        }

        // ── Keyboard bend: accumulated pitch ratio routed to selected tracks ──
        var _bendRatio = 1.0;

        function routePitch() {
            var sel = _root.getSelected(), acts = [];
            for (var i = 0; i < sel.length; i++)
                acts.push({ address: _sa(sel[i], "gran", "pitch"), value: _bendRatio });
            return acts;
        }

        // ── Source selection write ────────────────────────────────────────────
        function srcSelWrite(v) {
            var srcIdx = v.value;   // 0-7 → gain channel 1-8
            var sel = _root.getSelected(), acts = [];
            for (var i = 0; i < sel.length; i++) {
                var tr = sel[i];
                for (var g = 1; g <= 8; g++)
                    acts.push({ address: _sa(tr,"inmix","gain "+g),
                                value:   g === srcIdx+1 ? 1.0 : 0.0 });
            }
            return acts;
        }

        // ─────────────────────────────────────────────────────────────────────

        return [

            // ── Status ──────────────────────────────────────────────────────
            { name: "status", children: [
                { name: "xl_in",  type: Ossia.Type.String, value: "idle" },
                { name: "xl_out", type: Ossia.Type.String, value: "idle" },
                { name: "ml_in",  type: Ossia.Type.String, value: "idle" },
                { name: "ml_out", type: Ossia.Type.String, value: "idle" },
                { name: "ds1_in", type: Ossia.Type.String, value: "idle" },
                { name: "fbv_in", type: Ossia.Type.String, value: "idle" }
            ]},

            // ── Mode ─────────────────────────────────────────────────────────
            // spec §10 toggle:true equivalent — C++ would flip on note-on;
            // here handleXL toggles JS state and writes the updated Bool.
            { name: "mode", children: [
                { name: "track_sel", type: Ossia.Type.Int,  value: 1     },
                { name: "sel",       type: Ossia.Type.Bool, value: false  },
                { name: "rec",       type: Ossia.Type.Bool, value: false  },
                { name: "reset",     type: Ossia.Type.Bool, value: false  }
            ]},

            // ── Transport ────────────────────────────────────────────────────
            // spec §14 Mapping{to:"score:/global_play"} equivalent.
            { name: "transport", children: [
                { name: "play", type: Ossia.Type.Bool, value: false,
                  write: function(v) {
                      return v.value ? [{ address:"score:/global_play", value:true }] : null;
                  }
                },
                { name: "stop", type: Ossia.Type.Bool, value: false,
                  write: function(v) {
                      return v.value ? [{ address:"score:/global_stop", value:true }] : null;
                  }
                }
            ]},

            // ── Per-track strips (spec §9 Bank{count:8} pattern) ─────────────
            { name: "strip", children: strips },

            // ── MiniLab relative encoders (spec §10 encoder: Encoder.Offset64) ─
            { name: "encoder", children: [
                makeEnc("pos",          "pos",      0,    1,     "gran",      "position"),
                makeEnc("dur",          "dur",      0,    1,     "gran",      "duration"),
                makeEnc("density",      "density",  0,    256,   "gran",      "density"),
                makeEnc("dens_jit",     "densJit",  0,    1,     "gran",      "density jitter"),
                makeEnc("pos_jit",      "posJit",   0,    1,     "gran",      "position jitter"),
                makeEnc("dur_jit",      "durJit",   0,    1,     "gran",      "duration jitter"),
                makeEnc("pitch_jit",    "pitchJit", 0,    1,     "gran",      "pitch jitter"),
                makeEnc("ls_cutoff",    "lsCutoff", 20,   5000,  "Lowshelf",  "cutoff"),
                makeEnc("ls_gain",      "lsGain",   -24,  24,    "Lowshelf",  "gain"),
                makeEnc("bs_freq",      "bsFreq",   200,  15000, "Bandshelf", "frequency"),
                makeEnc("bs_gain",      "bsGain",   -24,  24,    "Bandshelf", "gain"),
                makeEnc("bs1_freq",     "bs1Freq",  20,   20000, "Bandshelf.1", "frequency"),
                makeEnc("bs1_gain",     "bs1Gain",  -24,  24,    "Bandshelf.1", "gain"),
                makeEnc("hs_cutoff",    "hsCutoff", 200,  15000, "Highshelf", "cutoff"),
                makeEnc("hs_gain",      "hsGain",   -24,  24,    "Highshelf", "gain"),
                // window coefs — sent as [winPos, winWidth] list
                {
                    name: "win_coefs", type: Ossia.Type.Float, value: 0.5,
                    write: function(v) {
                        var sel = _root.getSelected(), acts = [];
                        for (var i = 0; i < sel.length; i++) {
                            var tr = sel[i];
                            acts.push({ address: _sa(tr,"gran","window coefs"),
                                        value:  [_root._ts[tr].winPos, _root._ts[tr].winWidth] });
                            Device.write("/shadow/t" + tr + "/winPos",   _root._ts[tr].winPos);
                            Device.write("/shadow/t" + tr + "/winWidth", _root._ts[tr].winWidth);
                        }
                        return acts;
                    }
                },
                // CC20 absolute pitch jitter
                {
                    name: "pitch_jit_abs", type: Ossia.Type.Float, value: 0.0,
                    write: function(v) {
                        var sel = _root.getSelected(), acts = [];
                        for (var i = 0; i < sel.length; i++)
                            acts.push({ address: _sa(sel[i],"gran","pitch jitter"), value: v.value });
                        return acts;
                    }
                }
            ]},

            // ── Keyboard bend: accumulated pitch ratio → gran/pitch ─────────
            // pitch_tick fires every 50 ms (mirrors Max metro50): reads _pitchNorm
            // set by the MIDI handler and accumulates only while wheel is off-centre.
            { name: "keyboard", children: [
                {
                    name: "bend", type: Ossia.Type.Float, value: 1.0,
                    write: function(v) { _bendRatio = v.value; return routePitch(); }
                },
                {
                    name: "pitch_tick", type: Ossia.Type.Int, value: 0,
                    interval: 50,
                    read: function() {
                        var norm = _root._pitchNorm;
                        if (Math.abs(norm) >= 0.02) {
                            if (_root._pitchCentered) {
                                // First touch after wheel was at rest: reseed from score
                                var sel = _root.getSelected();
                                var pr = Device.read(_root.sa(sel[0], "gran", "pitch"));
                                if (pr !== null && pr !== undefined && pr > 0)
                                    _root._pitchAccum = Math.log(pr) / Math.log(2.5);
                                _root._pitchCentered = false;
                            }
                            _root._pitchAccum += norm / 400.0;
                            Device.write("/keyboard/bend", Math.pow(2.5, _root._pitchAccum));
                        } else {
                            _root._pitchCentered = true;
                        }
                        return 0;
                    }
                }
            ]},

            // ── Source selection (pads → inmix exclusive gain routing) ────────
            // spec §12.4 ColorFeedback: SysEx LED update happens in handleML.
            {
                name: "src_sel", type: Ossia.Type.Int, value: -1,
                write: srcSelWrite
            },

            // ── DS1 master gain (all 8 tracks simultaneously) ─────────────────
            { name: "ds1", children: [{
                name: "mix_gain", type: Ossia.Type.Float, value: 0.0,
                write: function(v) {
                    var acts = [];
                    for (var t = 1; t <= 8; t++)
                        acts.push({ address: _sa(t,"inmix","gain 1"), value: v.value });
                    return acts;
                }
            }]},

            // ── Startup initialiser ──────────────────────────────────────────
            // Fires every second; runs only once (_initDone guard).
            // Tries score addresses first; falls back to shadow nodes.
            {
                name: "startup_init", type: Ossia.Type.Int, value: 0,
                interval: 1000,
                read: function() {
                    if (!_root._initDone) {
                        for (var t = 1; t <= 8; t++) _root.initTrackFromScore(t);
                        // Seed pitch accumulator from score's current pitch value
                        var pr = Device.read(_root.sa(1, "gran", "pitch"));
                        if (pr === null || pr === undefined)
                            pr = Device.read("/shadow/t1/pitch");
                        if (pr !== null && pr !== undefined && pr > 0)
                            _root._pitchAccum = Math.log(pr) / Math.log(2.5);
                        // Seed MIDI gates: open only for initially selected tracks
                        for (var gt = 1; gt <= 8; gt++)
                            Device.write("/midi_gate/" + gt, _root._sel[gt-1]);
                        // Seed rec LEDs: all off on startup
                        _root.sendXLRecLEDs();
                        _root._initDone = true;
                    }
                    return 0;
                }
            },

            // ── Shadow: bind-free value holders on mapper device ─────────────
            // No bind → score never calls back → no deadlock.
            // Updated explicitly by makeEnc / win_coefs write callbacks so
            // initTrackFromScore can use them as fallback when score reads fail.
            // C++ fix (MapperDevice.cpp rootsChanged) keeps mapper device in
            // device_obj->devices so Device.read("/shadow/...") always resolves.
            { name: "shadow", children: (function() {
                var tracks = [];
                for (var n = 1; n <= 8; n++) {
                    tracks.push({ name: "t" + n, children: [
                        { name: "pos",      type: Ossia.Type.Float, value: 0.0 },
                        { name: "dur",      type: Ossia.Type.Float, value: 0.0 },
                        { name: "density",  type: Ossia.Type.Float, value: 0.0 },
                        { name: "densJit",  type: Ossia.Type.Float, value: 0.0 },
                        { name: "posJit",   type: Ossia.Type.Float, value: 0.0 },
                        { name: "durJit",   type: Ossia.Type.Float, value: 0.0 },
                        { name: "pitchJit", type: Ossia.Type.Float, value: 0.0 },
                        { name: "lsCutoff", type: Ossia.Type.Float, value: 0.0 },
                        { name: "lsGain",   type: Ossia.Type.Float, value: 0.0 },
                        { name: "bsFreq",   type: Ossia.Type.Float, value: 0.0 },
                        { name: "bsGain",   type: Ossia.Type.Float, value: 0.0 },
                        { name: "bs1Freq",  type: Ossia.Type.Float, value: 0.0 },
                        { name: "bs1Gain",  type: Ossia.Type.Float, value: 0.0 },
                        { name: "hsCutoff", type: Ossia.Type.Float, value: 0.0 },
                        { name: "hsGain",   type: Ossia.Type.Float, value: 0.0 },
                        { name: "pitch",    type: Ossia.Type.Float, value: 1.0 },
                        { name: "winPos",   type: Ossia.Type.Float, value: 0.5 },
                        { name: "winWidth", type: Ossia.Type.Float, value: 0.05 }
                    ]});
                }
                return tracks;
            }()) },

            // ── Per-track recording toggle (XL lower row buttons) ────────────
            // Each node writes to rec/record on its specific track.
            // toggleRec() also sends LED feedback directly via xlOut.
            { name: "rec", children: (function() {
                var nodes = [];
                for (var n = 1; n <= 8; n++) {
                    nodes.push((function(tr) {
                        return {
                            name: String(tr), type: Ossia.Type.Bool, value: false,
                            write: function(v) {
                                return [{ address: _sa(tr, "rec", "record"), value: v.value }];
                            }
                        };
                    })(n));
                }
                return nodes;
            }()) },

            // ── Granola MIDI gate: open/close per-track MIDI listening ───────
            { name: "midi_gate", children: (function() {
                var gates = [];
                for (var n = 1; n <= 8; n++) {
                    gates.push((function(tr) {
                        return {
                            name: String(tr), type: Ossia.Type.Bool, value: false,
                            write: function(v) {
                                return [{ address: _sa(tr, "gran", "midi gate"),
                                          value: v.value }];
                            }
                        };
                    })(n));
                }
                return gates;
            }()) },

            // ── Foot pedal — recording toggle on selected tracks ──────────────
            { name: "pedal", children: [{
                name: "rec", type: Ossia.Type.Float, value: 0.0,
                write: function(v) {
                    var sel = _root.getSelected(), acts = [];
                    for (var i = 0; i < sel.length; i++)
                        acts.push({ address: _sa(sel[i],"rec","record"), value: v.value > 0.5 });
                    return acts;
                }
            }]}

        ];
    }   // end createTree
}   // end Ossia.Mapper


// =============================================================================
// INTEGRATION NOTES
// =============================================================================
//
// 1. SCORE FILE: open jam-mapper.score (already configured with this mapper).
//    Devices panel contains only: score, route, audio, devices-mapper.
//    No separate MIDI devices needed — this mapper owns all 4 MIDI endpoints.
//
// 2. DEVICE TREE PATHS (visible in ossia Device Explorer after loading):
//    devices-mapper:/status/xl_in          String — connection status
//    devices-mapper:/mode/track_sel        Int    — last-focused track
//    devices-mapper:/mode/sel              Bool   — multi-select mode
//    devices-mapper:/strip/1/fader … /8/fader   Float [0,1]
//    devices-mapper:/strip/1/gain  … /8/gain    Float [0,2]
//    devices-mapper:/encoder/pos            Float — gran/position (sel. tracks)
//    devices-mapper:/keyboard/pitch         Float — pitch ratio
//    devices-mapper:/src_sel                Int   — active inmix source 0-7
//    … etc.
//
// 3. MIDI CHANNEL VERIFICATION (do this on first use):
//    Open the ossia MIDI device browser *before* loading this mapper.
//    a) Press a Track Focus button on LaunchControl XL — confirm ch 9 address.
//    b) Turn a MiniLab knob — confirm ch 1.
//    c) Press a MiniLab key — confirm ch 16.
//    d) Check pads — confirm ch 9, notes 36-43.
//    Adjust ch constants in handleXL / handleML if they differ.
//
// 4. KNOWN LIMITATIONS:
//    a) No per-track encoder memory across track switches: relative encoder
//       accumulates a single normalized value; switching selected track does not
//       restore the previous accumulated position. The score parameter value
//       diverges from the controller's accumulated position over time.
//       Workaround: use softTakeover patterns (not available in Ossia.Mapper;
//       would require the future ControllerMap API, spec §10 Parameter.Pickup).
//    b) Pitch bend address: if /keyboard/bend never fires, verify the pitch bend
//       status byte (0xE0) and channel (ch 1 = 0-based 0) in handleML.
