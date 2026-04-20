// devicesJAM-mapper.qml
// Replaces NXL+Arturia JAM/devicesJAM.maxpat as an ossia Mapper device.
// Works with jam-MBP.score (root interval named "ECHO", scenario named "s",
// tracks named "track.1" through "track.8").
//
// Controllers handled:
//   - Novation LaunchControl XL  : faders, knobs (rows 1-3), Track Focus buttons, mode buttons
//   - Arturia MiniLab mkII        : 16 relative knobs → selected track parameters
//   - DS1 DS_Controls             : CC49 → all-track mix gain
//   - FBV Express Mk II Port 1    : foot pedals → recording triggers
//
// MIDI channel assumptions (verify in ossia device browser):
//   Launch Control XL In:    channel 9  (all controls: faders, knobs rows 1-3, Track Focus + mode buttons)
//   Launch Control XL Out:   channel 9  (programmer mode, LEDs)
//   Arturia MiniLab mkII knobs:   channel 1  (from Relative preset)
//   Arturia MiniLab mkII keyboard: channel 16 (pitch_kb.maxpat used notein ch16)
//   Arturia MiniLab mkII pads:    channel 9  (from preset: fields 112_2–119_2 = 9)
//
// ossia Mapper address syntax:  Device:/channel/control/CC   or   Device:/channel/on/N
//
// NOTE: "read" functions return either:
//   - null / []                 → no action
//   - { address, value }        → send one message
//   - [{ address, value }, ...] → send multiple messages
//
// ── BLOCKER NOTES (features attempted but with caveats) ─────────────────────
//
// [BLOCKER-1] WILDCARD NOTE BINDING for keyboard pitch
//   Attempted: bind: "Arturia MiniLab mkII In:/16/on/*"
//   The "orig" parameter in read(orig, v) should carry the matched address so
//   we can parse the note number.  This relies on ossia Mapper supporting OSC
//   wildcard patterns in the bind property.  If wildcards are not resolved at
//   device-tree subscription time, the node will silently receive nothing.
//   Workaround if wildcards fail: expand to 128 explicit note nodes (impractical)
//   or add a dedicated small JS script device that listens via raw MIDI.
//
// [BLOCKER-2] PITCH BEND address name
//   Attempted: bind: "Arturia MiniLab mkII In:/1/pitchbend"
//   ossia's MIDI protocol may expose pitch bend as "/pitchbend", "/pitch_bend",
//   or not at all depending on version.  Verify in the device tree browser.
//   Value range assumed: -8192 to +8191 (standard 14-bit signed).  ossia may
//   expose it as 0–16383 instead; adjust the formula below accordingly.
//
// [BLOCKER-3] SYSEX for MiniLab pad LEDs — NOT IMPLEMENTABLE in QML Mapper
//   The Arturia MiniLab mkII pad LEDs require a proprietary SysEx message:
//     F0 00 20 6B 7F 42 02 00 10 <pad_index> <state> 00 00 F7
//   ossia's MIDI device tree exposes per-channel note/CC/pitchbend nodes but
//   does NOT currently expose a writable /sysex node.  There is no way to
//   send arbitrary SysEx bytes from within a QML Mapper read() function.
//   Impact: pad LEDs will not light up when a source is selected.  Audio
//   routing (the inmix gain switching) still works correctly without LEDs.
//   Possible future path: an ossia "script device" (JS/Python) with raw MIDI
//   access, or a future ossia feature that exposes /sysex as a writable node.
//
// [NOT A BLOCKER] RECORDING FILE ROUTING
//   Already wired inside the score itself: the avnd_audio_recorder "rec"
//   process has its "filename" outlet bound to route:/track.N/rec, and
//   granola "gran" has its "sound" inlet bound to the same address.  When
//   recording stops, the new file path flows automatically into gran/sound.
//   The QML Mapper only needs to toggle rec/record (done below via pedals).
// ────────────────────────────────────────────────────────────────────────────

import Ossia 1.0 as Ossia

Ossia.Mapper
{
    function createTree() {

        // =====================================================================
        // STATE (all mutable JS state lives here as closure variables)
        // =====================================================================

        // Track selection (1 = selected, 0 = not)
        var selectedTracks = { 1:false, 2:false, 3:false, 4:false,
                                5:false, 6:false, 7:false, 8:false };

        // Mode flags
        var selMode    = false;
        var recMode    = false;
        var resetMode  = false;

        // Per-track normalized accumulator state [0..1] for relative knobs.
        // Keys mirror the parameter names used in applyRel calls below.
        function makeTrackState() {
            return {
                pos:        0.0,   // gran/position
                dur:        1.0,   // gran/duration  (init to 1 = full file)
                winPos:     0.5,   // gran/window coefs [0] (Hann centre)
                winWidth:   0.05,  // gran/window coefs [1]
                density:    0.3,   // gran/density
                densJit:    0.0,   // gran/density jitter
                posJit:     0.0,   // gran/position jitter
                durJit:     0.0,   // gran/duration jitter
                pitchJit:   0.0,   // gran/pitch jitter
                lsCutoff:   0.048, // Lowshelf/cutoff   (250 Hz normalised in 20–5000)
                lsGain:     0.5,   // Lowshelf/gain     (0 dB → mid of −24…+24)
                bsFreq:     0.12,  // Bandshelf/frequency (2000 Hz norm in 200–15000)
                bsBw:       0.4,   // Bandshelf/bandwidth (1.0 norm in 0.2–1.8)
                bsGain:     0.5,   // Bandshelf/gain
                hsCutoff:   0.33,  // Highshelf/cutoff  (5000 Hz norm in 200–15000)
                hsGain:     0.5,   // Highshelf/gain
                hsSlope:    0.34,  // Highshelf/slope   (1.0 norm in 0.1–3.0)
                sourceIdx:  0      // inmix active source (0 = none selected)
            };
        }

        var trackState = {};
        for (var t = 1; t <= 8; t++) { trackState[t] = makeTrackState(); }

        // =====================================================================
        // HELPERS
        // =====================================================================

        // Build an ossia score address for a given track/process/param.
        function sa(trackN, process, param) {
            return "score:/ECHO/processes/s/intervals/track."
                   + trackN + "/processes/" + process + "/" + param + "/value";
        }

        // Return sorted array of currently selected track numbers.
        function getSelected() {
            var sel = [];
            for (var t = 1; t <= 8; t++) {
                if (selectedTracks[t]) sel.push(t);
            }
            return sel.length > 0 ? sel : [1]; // default: track 1
        }

        // Compute the LaunchControl XL note number for track n's Track Focus button.
        function ledNote(n) { return n <= 4 ? (40 + n) : (52 + n); }

        // Build the full LED update array for all 8 Track Focus buttons.
        function ledActions() {
            var acts = [];
            for (var t = 1; t <= 8; t++) {
                var vel = selectedTracks[t] ? (t <= 4 ? 60 : 62) : 0;
                acts.push({ address: "Launch Control XL Out:/9/on/" + ledNote(t), value: vel });
            }
            return acts;
        }

        // Select / deselect a track and return LED update actions.
        function selectTrack(n) {
            if (selMode) {
                selectedTracks[n] = !selectedTracks[n]; // toggle in multi-select mode
            } else {
                for (var t = 1; t <= 8; t++) selectedTracks[t] = false;
                selectedTracks[n] = true;
            }
            return ledActions();
        }

        // Relative CC delta accumulation.
        // rawCC in [0..127], centre = 64  →  delta = (rawCC - 64) / divisor
        // Returns new normalised value clamped to [0,1].
        function accum(current, rawCC, divisor) {
            var delta = (rawCC - 64) / (divisor || 256.0);
            var n = current + delta;
            return n < 0.0 ? 0.0 : (n > 1.0 ? 1.0 : n);
        }

        // Scale a normalised [0,1] value to [min, max].
        function scaleVal(v, min, max) { return min + v * (max - min); }

        // Apply a relative CC to stateKey on all selected tracks, send to score.
        // process/param = ossia process/parameter path segments
        // min/max = output range, divisor = encoder sensitivity (256 = fine, 32 = coarse)
        function applyRel(rawCC, stateKey, min, max, process, param, divisor) {
            var sel = getSelected();
            var acts = [];
            for (var i = 0; i < sel.length; i++) {
                var t = sel[i];
                trackState[t][stateKey] = accum(trackState[t][stateKey], rawCC, divisor);
                acts.push({
                    address: sa(t, process, param),
                    value:   scaleVal(trackState[t][stateKey], min, max)
                });
            }
            return acts;
        }

        // Apply an absolute CC (0-127) to all selected tracks.
        function applyAbs(rawCC, min, max, process, param) {
            var sel = getSelected();
            var acts = [];
            for (var i = 0; i < sel.length; i++) {
                acts.push({
                    address: sa(sel[i], process, param),
                    value:   min + (rawCC / 127.0) * (max - min)
                });
            }
            return acts;
        }

        // Apply an absolute CC to a SPECIFIC track (not selection-dependent).
        function applyAbsTrack(trackN, rawCC, min, max, process, param) {
            return [{
                address: sa(trackN, process, param),
                value:   min + (rawCC / 127.0) * (max - min)
            }];
        }

        // Reset all MiniLab accumulators for a given track to defaults.
        function resetTrack(n) {
            trackState[n] = makeTrackState();
        }

        // =====================================================================
        // TREE
        // =====================================================================

        return [

            // =================================================================
            // TRANSPORT
            // Note 105 = Stop in original Max patcher (ossia.remote stop).
            // global_play in Max was wired to spacebar (key 32) and a DS1 button.
            // ossia score already has its own transport UI; the spacebar shortcut
            // works natively.  We expose a button here for external MIDI control.
            // =================================================================

            {
                name: "transport_stop",
                bind: "Launch Control XL In:/9/on/105",
                type: Ossia.Type.Int,
                read: function(orig, v) {
                    if (v.value !== 127) return null;
                    return { address: "score:/global_stop", value: true };
                }
            },

            // global_play: bind to a spare button on LaunchControl XL (note 104
            // is unused in the original patch; adjust to whatever button you prefer)
            {
                name: "transport_play",
                bind: "Launch Control XL In:/9/on/104",
                type: Ossia.Type.Int,
                read: function(orig, v) {
                    if (v.value !== 127) return null;
                    return { address: "score:/global_play", value: true };
                }
            },

            // =================================================================
            // MODE BUTTONS (LaunchControl XL, channel 9)
            // =================================================================

            {
                name: "sel_mode",
                bind: "Launch Control XL In:/9/on/106",
                type: Ossia.Type.Int,
                read: function(orig, v) {
                    if (v.value !== 127) return null;
                    selMode = !selMode;
                    var acts = ledActions();
                    acts.push({
                        address: "Launch Control XL Out:/9/on/106",
                        value:   selMode ? 60 : 0
                    });
                    return acts;
                }
            },

            {
                name: "reset_mode",
                bind: "Launch Control XL In:/9/on/107",
                type: Ossia.Type.Int,
                read: function(orig, v) {
                    if (v.value !== 127) return null;
                    resetMode = !resetMode;
                    if (resetMode) {
                        // Reset accumulators for all selected tracks
                        var sel = getSelected();
                        for (var i = 0; i < sel.length; i++) resetTrack(sel[i]);
                    }
                    return [{
                        address: "Launch Control XL Out:/9/on/107",
                        value:   resetMode ? 60 : 0
                    }];
                }
            },

            {
                name: "rec_mode",
                bind: "Launch Control XL In:/9/on/108",
                type: Ossia.Type.Int,
                read: function(orig, v) {
                    if (v.value !== 127) return null;
                    recMode = !recMode;
                    return [{
                        address: "Launch Control XL Out:/9/on/108",
                        value:   recMode ? 60 : 0
                    }];
                }
            },

            // =================================================================
            // TRACK FOCUS BUTTONS — select which track(s) MiniLab controls
            // Notes 41-44 = tracks 1-4 ; notes 57-60 = tracks 5-8
            // =================================================================

            { name:"sel_1", bind:"Launch Control XL In:/9/on/41", type:Ossia.Type.Int,
              read: function(o,v){ return v.value===127 ? selectTrack(1) : null; } },
            { name:"sel_2", bind:"Launch Control XL In:/9/on/42", type:Ossia.Type.Int,
              read: function(o,v){ return v.value===127 ? selectTrack(2) : null; } },
            { name:"sel_3", bind:"Launch Control XL In:/9/on/43", type:Ossia.Type.Int,
              read: function(o,v){ return v.value===127 ? selectTrack(3) : null; } },
            { name:"sel_4", bind:"Launch Control XL In:/9/on/44", type:Ossia.Type.Int,
              read: function(o,v){ return v.value===127 ? selectTrack(4) : null; } },
            { name:"sel_5", bind:"Launch Control XL In:/9/on/57", type:Ossia.Type.Int,
              read: function(o,v){ return v.value===127 ? selectTrack(5) : null; } },
            { name:"sel_6", bind:"Launch Control XL In:/9/on/58", type:Ossia.Type.Int,
              read: function(o,v){ return v.value===127 ? selectTrack(6) : null; } },
            { name:"sel_7", bind:"Launch Control XL In:/9/on/59", type:Ossia.Type.Int,
              read: function(o,v){ return v.value===127 ? selectTrack(7) : null; } },
            { name:"sel_8", bind:"Launch Control XL In:/9/on/60", type:Ossia.Type.Int,
              read: function(o,v){ return v.value===127 ? selectTrack(8) : null; } },

            // =================================================================
            // LAUNCH CONTROL XL — ROW 1 KNOBS → gran/gain (per-track, direct)
            // CC = 12 + trackN (13–20), channel 1
            // value / 64.  →  [0, 2]  (gain can exceed 1.0)
            // =================================================================

            { name:"gain_1", bind:"Launch Control XL In:/9/control/13", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(1,v.value,0,2,"gran","gain"); } },
            { name:"gain_2", bind:"Launch Control XL In:/9/control/14", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(2,v.value,0,2,"gran","gain"); } },
            { name:"gain_3", bind:"Launch Control XL In:/9/control/15", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(3,v.value,0,2,"gran","gain"); } },
            { name:"gain_4", bind:"Launch Control XL In:/9/control/16", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(4,v.value,0,2,"gran","gain"); } },
            { name:"gain_5", bind:"Launch Control XL In:/9/control/17", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(5,v.value,0,2,"gran","gain"); } },
            { name:"gain_6", bind:"Launch Control XL In:/9/control/18", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(6,v.value,0,2,"gran","gain"); } },
            { name:"gain_7", bind:"Launch Control XL In:/9/control/19", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(7,v.value,0,2,"gran","gain"); } },
            { name:"gain_8", bind:"Launch Control XL In:/9/control/20", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(8,v.value,0,2,"gran","gain"); } },

            // =================================================================
            // LAUNCH CONTROL XL — ROW 2 KNOBS → qpan/f_b (per-track)
            // CC = 28 + trackN (29–36), channel 1
            // (val / 63.5) - 1.  →  [-1, +1]
            // =================================================================

            { name:"fb_1", bind:"Launch Control XL In:/9/control/29", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(1,v.value,-1,1,"qpan","f_b"); } },
            { name:"fb_2", bind:"Launch Control XL In:/9/control/30", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(2,v.value,-1,1,"qpan","f_b"); } },
            { name:"fb_3", bind:"Launch Control XL In:/9/control/31", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(3,v.value,-1,1,"qpan","f_b"); } },
            { name:"fb_4", bind:"Launch Control XL In:/9/control/32", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(4,v.value,-1,1,"qpan","f_b"); } },
            { name:"fb_5", bind:"Launch Control XL In:/9/control/33", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(5,v.value,-1,1,"qpan","f_b"); } },
            { name:"fb_6", bind:"Launch Control XL In:/9/control/34", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(6,v.value,-1,1,"qpan","f_b"); } },
            { name:"fb_7", bind:"Launch Control XL In:/9/control/35", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(7,v.value,-1,1,"qpan","f_b"); } },
            { name:"fb_8", bind:"Launch Control XL In:/9/control/36", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(8,v.value,-1,1,"qpan","f_b"); } },

            // =================================================================
            // LAUNCH CONTROL XL — ROW 3 KNOBS → qpan/l_r (per-track)
            // CC = 48 + trackN (49–56), channel 1
            // =================================================================

            { name:"lr_1", bind:"Launch Control XL In:/9/control/49", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(1,v.value,-1,1,"qpan","l_r"); } },
            { name:"lr_2", bind:"Launch Control XL In:/9/control/50", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(2,v.value,-1,1,"qpan","l_r"); } },
            { name:"lr_3", bind:"Launch Control XL In:/9/control/51", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(3,v.value,-1,1,"qpan","l_r"); } },
            { name:"lr_4", bind:"Launch Control XL In:/9/control/52", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(4,v.value,-1,1,"qpan","l_r"); } },
            { name:"lr_5", bind:"Launch Control XL In:/9/control/53", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(5,v.value,-1,1,"qpan","l_r"); } },
            { name:"lr_6", bind:"Launch Control XL In:/9/control/54", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(6,v.value,-1,1,"qpan","l_r"); } },
            { name:"lr_7", bind:"Launch Control XL In:/9/control/55", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(7,v.value,-1,1,"qpan","l_r"); } },
            { name:"lr_8", bind:"Launch Control XL In:/9/control/56", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(8,v.value,-1,1,"qpan","l_r"); } },

            // =================================================================
            // LAUNCH CONTROL XL — FADERS → qpan/gain (per-track)
            // CC = 76 + trackN (77–84), channel 1
            // value / 127.  →  [0, 1]
            // =================================================================

            { name:"fader_1", bind:"Launch Control XL In:/9/control/77", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(1,v.value,0,1,"qpan","gain"); } },
            { name:"fader_2", bind:"Launch Control XL In:/9/control/78", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(2,v.value,0,1,"qpan","gain"); } },
            { name:"fader_3", bind:"Launch Control XL In:/9/control/79", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(3,v.value,0,1,"qpan","gain"); } },
            { name:"fader_4", bind:"Launch Control XL In:/9/control/80", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(4,v.value,0,1,"qpan","gain"); } },
            { name:"fader_5", bind:"Launch Control XL In:/9/control/81", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(5,v.value,0,1,"qpan","gain"); } },
            { name:"fader_6", bind:"Launch Control XL In:/9/control/82", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(6,v.value,0,1,"qpan","gain"); } },
            { name:"fader_7", bind:"Launch Control XL In:/9/control/83", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(7,v.value,0,1,"qpan","gain"); } },
            { name:"fader_8", bind:"Launch Control XL In:/9/control/84", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbsTrack(8,v.value,0,1,"qpan","gain"); } },

            // =================================================================
            // ARTURIA MINILAB MKII — RELATIVE KNOBS → selected track(s)
            // All on channel 1, relative mode: centre=64, ±step = ±1/256
            // =================================================================

            // CC1  — gran/density jitter (k_jitter, accumulates fine)
            { name:"dens_jit", bind:"Arturia MiniLab mkII In:/1/control/1", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"densJit",0,1,"gran","density jitter",256); } },

            // CC2  — gran/position   (k_set_lo, range 0–1)
            { name:"gran_pos", bind:"Arturia MiniLab mkII In:/1/control/2", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"pos",0,1,"gran","position",256); } },

            // CC3  — gran/duration   (k_set_lo, range 0–1)
            { name:"gran_dur", bind:"Arturia MiniLab mkII In:/1/control/3", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"dur",0,1,"gran","duration",256); } },

            // CC4  — gran/window coefs (win_coefs: two-value pack [pos, width])
            //         Map to the first coefficient (window position/shape centre).
            { name:"win_coefs", bind:"Arturia MiniLab mkII In:/1/control/4", type:Ossia.Type.Int,
              read: function(o,v) {
                var sel = getSelected();
                var acts = [];
                for (var i = 0; i < sel.length; i++) {
                    var t = sel[i];
                    trackState[t].winPos = accum(trackState[t].winPos, v.value, 256);
                    acts.push({
                        address: sa(t, "gran", "window coefs"),
                        value: [trackState[t].winPos, trackState[t].winWidth]
                    });
                }
                return acts;
              }
            },

            // CC5  — Lowshelf/cutoff  (k_set, range 20–5000 Hz)
            { name:"ls_cutoff", bind:"Arturia MiniLab mkII In:/1/control/5", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"lsCutoff",20,5000,"Lowshelf","cutoff",256); } },

            // CC6  — Bandshelf/frequency  (k_set, range 200–15000 Hz)
            { name:"bs_freq", bind:"Arturia MiniLab mkII In:/1/control/6", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"bsFreq",200,15000,"Bandshelf","frequency",256); } },

            // CC7  — Bandshelf/bandwidth  (k_set, range 0.2–1.8)
            { name:"bs_bw", bind:"Arturia MiniLab mkII In:/1/control/7", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"bsBw",0.2,1.8,"Bandshelf","bandwidth",256); } },

            // CC8  — Highshelf/cutoff  (k_set, range 200–15000 Hz)
            { name:"hs_cutoff", bind:"Arturia MiniLab mkII In:/1/control/8", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"hsCutoff",200,15000,"Highshelf","cutoff",256); } },

            // CC9  — gran/density  (density.maxpat, range 0–1)
            { name:"gran_dens", bind:"Arturia MiniLab mkII In:/1/control/9", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"density",0,1,"gran","density",256); } },

            // CC10 — gran/position jitter  (k_jitter)
            { name:"pos_jit", bind:"Arturia MiniLab mkII In:/1/control/10", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"posJit",0,1,"gran","position jitter",256); } },

            // CC11 — gran/duration jitter  (k_jitter)
            { name:"dur_jit", bind:"Arturia MiniLab mkII In:/1/control/11", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"durJit",0,1,"gran","duration jitter",256); } },

            // CC12 — gran/pitch jitter via relative encoder  (k_jitter / pitch_kb)
            { name:"pitch_jit_rel", bind:"Arturia MiniLab mkII In:/1/control/12", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"pitchJit",0,1,"gran","pitch jitter",256); } },

            // CC13 — Lowshelf/gain  (k_set, range −24…+24 dB, coarser /32.)
            { name:"ls_gain", bind:"Arturia MiniLab mkII In:/1/control/13", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"lsGain",-24,24,"Lowshelf","gain",32); } },

            // CC14 — Bandshelf/gain  (k_set, range −24…+24 dB)
            { name:"bs_gain", bind:"Arturia MiniLab mkII In:/1/control/14", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"bsGain",-24,24,"Bandshelf","gain",32); } },

            // CC15 — Highshelf/slope  (k_set, range 0.1–3.0)
            { name:"hs_slope", bind:"Arturia MiniLab mkII In:/1/control/15", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"hsSlope",0.1,3.0,"Highshelf","slope",256); } },

            // CC16 — Highshelf/gain  (k_set, range −24…+24 dB)
            { name:"hs_gain", bind:"Arturia MiniLab mkII In:/1/control/16", type:Ossia.Type.Int,
              read: function(o,v){ return applyRel(v.value,"hsGain",-24,24,"Highshelf","gain",32); } },

            // CC20 — gran/pitch jitter ABSOLUTE  (pitch_kb: direct mapping)
            { name:"pitch_jit_abs", bind:"Arturia MiniLab mkII In:/1/control/20", type:Ossia.Type.Int,
              read: function(o,v){ return applyAbs(v.value,0,1,"gran","pitch jitter"); } },

            // =================================================================
            // MINILAB KEYBOARD → gran/pitch  [see BLOCKER-1]
            //
            // pitch_kb.maxpat logic:
            //   notein ch16 → note_number → mtof(note) / mtof(60)  → pitch ratio
            //   (so middle C = 1.0, one octave up = 2.0, etc.)
            //   The ratio is gated by track selection and sent to gran/pitch/value.
            //
            // Attempt: wildcard bind captures all 128 notes.  The matched address
            // is passed as "orig" so we can parse the note number from it.
            // If the wildcard is not supported, this node receives nothing —
            // no crash, just silence.  See BLOCKER-1 above for workaround.
            // =================================================================

            {
                name: "kb_pitch",
                bind: "Arturia MiniLab mkII In:/16/on/*",   // [BLOCKER-1] wildcard
                type: Ossia.Type.Int,
                read: function(orig, v) {
                    // Ignore note-off (velocity == 0)
                    if (v.value === 0) return null;

                    // Parse note number from the address string, e.g.:
                    //   "Arturia MiniLab mkII:/16/on/60"  → 60
                    var parts = orig.split('/');
                    var noteN = parseInt(parts[parts.length - 1], 10);
                    if (isNaN(noteN)) return null;

                    // Convert to frequency ratio relative to middle C (note 60).
                    // gran/pitch = 1.0 means "play at original speed".
                    // 2^((noteN-60)/12) gives the standard equal-temperament ratio.
                    var pitchRatio = Math.pow(2.0, (noteN - 60) / 12.0);

                    var sel = getSelected();
                    var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        acts.push({ address: sa(sel[i], "gran", "pitch"), value: pitchRatio });
                    }
                    return acts;
                }
            },

            // =================================================================
            // MINILAB PITCH BEND → gran/pitch fine control  [see BLOCKER-2]
            //
            // pitch_kb.maxpat logic (simplified):
            //   xbendin → /8192. → -1. → [-2, ~0], centre = 0 when no bend
            //   This drives a slow accumulator that modulates the pitch.
            //   Here we implement a direct ±2-semitone pitch bend (simpler
            //   and equivalent for live performance).
            //   Formula: pitchBend / 8192 * 2  semitones → ratio = 2^(semi/12)
            //
            // Address: ossia MIDI protocol may expose pitchbend as:
            //   "Device:/channel/pitchbend"  — value range 0–16383 (unsigned)
            //   or -8192 to +8191 (signed), depending on ossia version.
            //   The code below handles the unsigned 0–16383 case (subtract 8192
            //   to get signed).  If ossia delivers signed values, remove the -8192.
            // =================================================================

            {
                name: "kb_pitchbend",
                bind: "Arturia MiniLab mkII In:/1/pitchbend",  // [BLOCKER-2] verify address
                type: Ossia.Type.Int,
                read: function(orig, v) {
                    // Assume ossia delivers 0–16383; centre = 8192 = no bend.
                    // If your ossia version delivers -8192–8191, change next line to:
                    //   var signed = v;
                    var signed = v.value - 8192;

                    // ±2 semitones range
                    var semitones = (signed / 8192.0) * 2.0;
                    var pitchRatio = Math.pow(2.0, semitones / 12.0);

                    var sel = getSelected();
                    var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        acts.push({ address: sa(sel[i], "gran", "pitch"), value: pitchRatio });
                    }
                    return acts;
                }
            },

            // =================================================================
            // SOURCE SELECTION — MiniLab pads (notes 36–43, ch 9)
            // Each pad selects one input source for the selected track's inmix.
            // Exclusive: sets chosen gain channel to 1.0, all others to 0.0.
            //
            // PAD LED FEEDBACK [BLOCKER-3]:
            //   The original Max patch sends Arturia SysEx to light pad LEDs:
            //     F0 00 20 6B 7F 42 02 00 10 <pad_idx> <state> 00 00 F7
            //   ossia has no writable /sysex node on MIDI devices, so LED
            //   feedback is not implementable here.  The gain switching itself
            //   works correctly.  A helper script (Python/JS) with rtmidi could
            //   listen to OSC from ossia and send the SysEx independently.
            // =================================================================

            // Helper built into closure: returns source-select gain actions
            // plus (attempted) LED feedback for pad notes on channel 9.
            // The "led" lines write note-on velocity 127 to the selected pad
            // and 0 to all others — this WILL NOT light MiniLab LEDs (SysEx
            // needed) but leaves the code ready if ossia ever adds sysex support.

            {
                name: "src_sel_0",
                bind: "Arturia MiniLab mkII In:/10/control/40",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    if (v.value === 0) return null;
                    var sel = getSelected();
                    var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        var t = sel[i];
                        for (var g = 1; g <= 8; g++)
                            acts.push({ address: sa(t,"inmix","gain "+g), value: g===1?1.0:0.0 });
                    }
                    // Attempted LED: note-on on same channel (won't drive MiniLab LEDs)
                    for (var p = 40; p <= 47; p++)
                        acts.push({ address: "Arturia MiniLab mkII Out:/9/on/"+p, value: p===44?127:0 });
                    return acts;
                }
            },
            {
                name: "src_sel_1",
                bind: "Arturia MiniLab mkII In:/10/control/41",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    if (v.value === 0) return null;
                    var sel = getSelected(); var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        var t = sel[i];
                        for (var g = 1; g <= 8; g++)
                            acts.push({ address: sa(t,"inmix","gain "+g), value: g===2?1.0:0.0 });
                    }
                    for (var p = 40; p <= 47; p++)
                        acts.push({ address: "Arturia MiniLab mkII Out:/9/on/"+p, value: p===45?127:0 });
                    return acts;
                }
            },
            {
                name: "src_sel_2",
                bind: "Arturia MiniLab mkII In:/10/control/42",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    if (v.value === 0) return null;
                    var sel = getSelected(); var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        var t = sel[i];
                        for (var g = 1; g <= 8; g++)
                            acts.push({ address: sa(t,"inmix","gain "+g), value: g===3?1.0:0.0 });
                    }
                    for (var p = 40; p <= 47; p++)
                        acts.push({ address: "Arturia MiniLab mkII Out:/9/on/"+p, value: p===46?127:0 });
                    return acts;
                }
            },
            {
                name: "src_sel_3",
                bind: "Arturia MiniLab mkII In:/10/control/43",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    if (v.value === 0) return null;
                    var sel = getSelected(); var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        var t = sel[i];
                        for (var g = 1; g <= 8; g++)
                            acts.push({ address: sa(t,"inmix","gain "+g), value: g===4?1.0:0.0 });
                    }
                    for (var p = 40; p <= 47; p++)
                        acts.push({ address: "Arturia MiniLab mkII Out:/9/on/"+p, value: p===47?127:0 });
                    return acts;
                }
            },
            {
                name: "src_sel_4",
                bind: "Arturia MiniLab mkII In:/10/control/44",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    if (v.value === 0) return null;
                    var sel = getSelected(); var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        var t = sel[i];
                        for (var g = 1; g <= 8; g++)
                            acts.push({ address: sa(t,"inmix","gain "+g), value: g===5?1.0:0.0 });
                    }
                    for (var p = 40; p <= 47; p++)
                        acts.push({ address: "Arturia MiniLab mkII Out:/9/on/"+p, value: p===44?127:0 });
                    return acts;
                }
            },
            {
                name: "src_sel_5",
                bind: "Arturia MiniLab mkII In:/10/control/45",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    if (v.value === 0) return null;
                    var sel = getSelected(); var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        var t = sel[i];
                        for (var g = 1; g <= 8; g++)
                            acts.push({ address: sa(t,"inmix","gain "+g), value: g===6?1.0:0.0 });
                    }
                    for (var p = 40; p <= 47; p++)
                        acts.push({ address: "Arturia MiniLab mkII Out:/9/on/"+p, value: p===45?127:0 });
                    return acts;
                }
            },
            {
                name: "src_sel_6",
                bind: "Arturia MiniLab mkII In:/10/control/46",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    if (v.value === 0) return null;
                    var sel = getSelected(); var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        var t = sel[i];
                        for (var g = 1; g <= 8; g++)
                            acts.push({ address: sa(t,"inmix","gain "+g), value: g===7?1.0:0.0 });
                    }
                    for (var p = 40; p <= 47; p++)
                        acts.push({ address: "Arturia MiniLab mkII Out:/9/on/"+p, value: p===46?127:0 });
                    return acts;
                }
            },
            {
                name: "src_sel_7",
                bind: "Arturia MiniLab mkII In:/10/control/47",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    if (v.value === 0) return null;
                    var sel = getSelected(); var acts = [];
                    for (var i = 0; i < sel.length; i++) {
                        var t = sel[i];
                        for (var g = 1; g <= 8; g++)
                            acts.push({ address: sa(t,"inmix","gain "+g), value: g===8?1.0:0.0 });
                    }
                    for (var p = 40; p <= 47; p++)
                        acts.push({ address: "Arturia MiniLab mkII Out:/9/on/"+p, value: p===47?127:0 });
                    return acts;
                }
            },

            // =================================================================
            // DS1 DS_CONTROLS — CC49 → mix gain (applied to ALL tracks)
            // Original: ossia.remote wildcard "track.*/processes/mix/gain 1/value"
            // In QML we enumerate tracks explicitly.
            // =================================================================

            {
                name: "ds1_mix_gain",
                bind: "DS1 DS_Controls:/1/control/49",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    var val = v.value / 64.0;  // 0–2 range
                    var acts = [];
                    for (var t = 1; t <= 8; t++) {
                        acts.push({ address: sa(t,"inmix","gain 1"), value: val });
                    }
                    return acts;
                }
            },

            // =================================================================
            // FBV EXPRESS MK II — foot pedals → recording
            // CC1 and CC2 trigger pedalRec (start/stop recording on selected tracks)
            // =================================================================

            {
                name: "pedal_1",
                bind: "FBV Express Mk II Port 1:/1/control/1",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    var sel = getSelected();
                    var acts = [];
                    var rec = v.value / 127.0;
                    for (var i = 0; i < sel.length; i++) {
                        // Toggle rec process "record" parameter (Bool)
                        acts.push({ address: sa(sel[i],"rec","record"), value: rec > 0.5 });
                    }
                    return acts;
                }
            },

            {
                name: "pedal_2",
                bind: "FBV Express Mk II Port 1:/1/control/2",
                type: Ossia.Type.Int,
                read: function(o,v) {
                    var sel = getSelected();
                    var acts = [];
                    var rec = v.value / 127.0;
                    for (var i = 0; i < sel.length; i++) {
                        acts.push({ address: sa(sel[i],"rec","record"), value: rec > 0.5 });
                    }
                    return acts;
                }
            }

        ]; // end return
    } // end createTree
} // end Ossia.Mapper


// =============================================================================
// INTEGRATION NOTES
// =============================================================================
//
// 1. DEVICES TO ADD IN jam-MBP.score (Devices panel):
//    - "Launch Control XL"        MIDI device (in+out, for LED feedback)
//    - "Arturia MiniLab mkII"     MIDI device (in+out)
//    - "DS1 DS_Controls"          MIDI device (in)
//    - "FBV Express Mk II Port 1" MIDI device (in)
//    Load the "Relative.minilabmk2" preset into the MiniLab before use.
//
// 2. ADD THIS FILE AS A MAPPER DEVICE:
//    Devices panel → (+) → "QML Mapper" → select this file.
//    The mapper appears in the device list and handles its own state.
//
// 3. CHANNEL VERIFICATION — do this before first use:
//    Open the ossia MIDI device browser.
//    a) Press a Track Focus button on LaunchControl XL and note which address
//       lights up.  Adjust "Launch Control XL:/9/on/..." to the actual channel.
//    b) Turn a MiniLab knob; confirm "Arturia MiniLab mkII:/1/control/..." is correct.
//    c) Press a MiniLab key; confirm the keyboard channel (expected: 16).
//    d) Search for "pitchbend" in the MiniLab tree to confirm the address format.
//    The BLOCKER-1 and BLOCKER-2 items above will resolve once channels are confirmed.
//
// 4. RECORDING:
//    - Foot pedals (FBV CC1/CC2) toggle rec/record on selected tracks.
//    - The score already wires rec→filename to gran→sound via route:/track.N/rec,
//      so the new file automatically loads into the granulator on stop.
//    - No coll/file-management needed; the route device handles it.
//
// 5. KNOWN LIMITATIONS after this implementation:
//    a) Pad LEDs (BLOCKER-3, SysEx): pads still work for source selection;
//       only visual feedback is missing.
//       Workaround: write a small Python/Node script using python-rtmidi that
//       subscribes to an ossia OSC address and sends the SysEx on MiniLab:
//         F0 00 20 6B 7F 42 02 00 10 <pad_idx> <1_or_0> 00 00 F7
//
//    b) Keyboard pitch (BLOCKER-1): if wildcard bind is not supported by your
//       ossia version, kb_pitch receives nothing.  No error, just no response.
//       Test by opening the score log console — if "kb_pitch" node never fires,
//       wildcards are unsupported.  The pitch bend still works independently.
//
//    c) Pitch bend address (BLOCKER-2): if the node never fires, open the
//       device tree browser, find the pitchbend node name, and update the bind.
//
//    d) The nanoKONTROL2 listed in jam-MBP.score devices is not used in the
//       original Max patcher and is not mapped here.
