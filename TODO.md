  ---
  What was implemented and what's blocked                                                                                 
                                                                  
  ✅ Implemented (now in the QML)                                                                                         
                                                                                                                          
  Keyboard pitch (kb_pitch node): uses bind: "Arturia MiniLab mkII:/16/note/*" — a wildcard that should capture all 128   
  notes. The orig parameter in read(orig, v) gives the full matched address (e.g. "…/note/60"), from which we parse the   
  note number and compute 2^((note-60)/12) as a pitch ratio for gran/pitch/value.                                         


Pitch bend (kb_pitchbend node): binds to "Arturia MiniLab mkII:/1/pitchbend". Converts the 14-bit value to ±2 semitones 
  using 2^(semitones/12) and sends to gran/pitch/value. The formula handles both unsigned (0–16383) and signed
  (−8192..+8191) ossia representations with a one-line comment showing how to switch.                                     
                                                                  
  Recording: turns out to be not a blocker at all — the score already wires rec/filename → route:/track.N/rec → gran/sound
   internally. The foot pedal nodes (FBV CC1/CC2 → rec/record) are already in the mapper and that's all that's needed.
                                                                                                                          
  Pad source selection: all 8 pads (notes 36–43) implemented with exclusive gain switching. Includes attempted note-on LED
   feedback (won't work, see below).
                                                                                                                          
  ❌ Hard blocker                                                 

  MiniLab pad LEDs (SysEx) — genuinely not implementable in the current QML Mapper. The MiniLab mkII has no note-on–based 
  LED control; its pads require a proprietary Arturia SysEx message:
  F0 00 20 6B 7F 42 02 00 10 <pad_index> <state> 00 00 F7                                                                 
  ossia's MIDI device tree exposes /note, /control, /pitchbend per channel but has no writable /sysex node — there is no
  path from a Mapper read() function to raw MIDI bytes. The workaround is a small external script (Python rtmidi, ~15     
  lines) that subscribes to an ossia OSC address and fires the SysEx independently of the Mapper.                         
                                                                                                                          
  ⚠ Conditional (needs verification)                                                                                      
                                                                                                                          
  Wildcard bind ([BLOCKER-1]): works only if ossia's Mapper evaluates OSC wildcard patterns in bind at subscription time. 
  If not, the kb_pitch node silently receives nothing. Test: turn a key → check ossia log. If it never fires, the         
  workaround is 128 individual note nodes (ugly but functional).                                                          
                                                                  
  Pitchbend address ([BLOCKER-2]): depends on what ossia's MIDI protocol actually names the pitchbend node. Open the      
  device tree browser and search — it might be /pitchbend, /pitch_bend, or missing entirely. Adjust the bind string once
  confirmed.                 