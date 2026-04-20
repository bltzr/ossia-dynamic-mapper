# ossia score — QML MIDI Controller Map API

## Complete Specification — Version 2.0

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Module Import](#3-module-import)
4. [ControllerMap — Root Object](#4-controllermap--root-object)
5. [EndpointFilter — Device Matching](#5-endpointfilter--device-matching)
6. [Init and DeInit Sequences](#6-init-and-deinit-sequences)
7. [Tree — The Exposed Device Tree](#7-tree--the-exposed-device-tree)
8. [Node — Namespace Container](#8-node--namespace-container)
9. [Bank — Repeated Children](#9-bank--repeated-children)
10. [Parameter — Leaf Address](#10-parameter--leaf-address)
11. [UmpBind — Packet Match Pattern](#11-umpbind--packet-match-pattern)
12. [Feedback Types](#12-feedback-types)
13. [Layers](#13-layers)
14. [Mapping — Address Binding](#14-mapping--address-binding)
15. [Rebind — Binding Override](#15-rebind--binding-override)
16. [Script — Imperative Escape Hatch](#16-script--imperative-escape-hatch)
17. [Ump — Packet Factory](#17-ump--packet-factory)
18. [Tree Helper — Script Access to Parameters](#18-tree-helper--script-access-to-parameters)
19. [Profiles and Property Exchange](#19-profiles-and-property-exchange)
20. [Multi-Endpoint Composition](#20-multi-endpoint-composition)
21. [Dynamic Tree Creation](#21-dynamic-tree-creation)
22. [Composability — Reusable QML Components](#22-composability--reusable-qml-components)
23. [Auto-Created Sibling Parameters](#23-auto-created-sibling-parameters)
24. [Enumerations Reference](#24-enumerations-reference)
25. [Type Catalogue](#25-type-catalogue)
26. [C++ Responsibilities](#26-c-responsibilities)
27. [Complete Example — Behringer X-Touch (MCU)](#27-complete-example--behringer-x-touch-mcu)

---

## 1. Overview

A Controller Map is an **ossia device protocol**. It receives raw UMP (Universal MIDI Packet) data directly from C++ (which interfaces with the OS MIDI driver), and **produces a high-level device tree** with human-readable names, appropriate value types, and built-in feedback logic.

The user never sees raw MIDI addresses. Instead of `midi:/0/0/cc/47`, the user sees `X-Touch:/strip/3/pan` in the ossia score Device Explorer.

### Design principles

- **MIDI 2.0 / UMP is the sole internal representation.** There is no MIDI 1.0 API surface. Legacy devices are upscaled to UMP at the OS transport layer (macOS CoreMIDI 2.0, Windows MIDI Services, ALSA UMP).
- **All values are full MIDI 2.0 resolution.** Controller values are 32-bit, velocity is 16-bit, pitch bend is 32-bit. C++ normalises these to `[0.0, 1.0]` (or `[-1.0, 1.0]` for bipolar controls) before passing them to the QML tree.
- **Declarative-first, scriptable escape hatch.** The tree structure, bindings, transforms, feedback, and layers are declared in QML. Complex protocol logic (SysEx, displays) uses inline JavaScript in a `Script` block.
- **Generic device support.** A map can target a specific device (via `EndpointFilter`) or work as a generic mapping that the user manually assigns to any MIDI Endpoint.

---

## 2. Architecture

```
 ┌───────────────┐   raw UMP    ┌───────────┐  dispatch  ┌──────────────────┐
 │ Physical MIDI │─────────────▶│   C++     │──────────▶│  QML             │
 │ Endpoint      │◀─────────────│   UMP I/O │◀──────────│  ControllerMap   │
 └───────────────┘   feedback   └───────────┘  feedback  └──────────────────┘
                                                                │
                                                                │ produces
                                                                ▼
                                                    ┌──────────────────────┐
                                                    │  ossia device tree   │
                                                    └──────────────────────┘
```

**C++ owns** all performance-critical work: UMP I/O, packet matching, value normalisation, encoder accumulation, soft-takeover, toggle state, timers (long-press, double-press, blink), feedback UMP construction, and writing values into the ossia device tree. See §26 for the full list.

**QML owns** the declarative description: tree structure, bindings, transforms, feedback rules, layers, and script logic.

There is **no intermediate ossia MIDI device tree**. When a Controller Map is active for an Endpoint, it replaces the raw MIDI tree entirely.

---

## 3. Module Import

```qml
import Ossia 1.0 as Ossia
import Ossia.Midi 1.0
```

`Ossia.Midi 1.0` provides all types documented in this specification.

---

## 4. ControllerMap — Root Object

One file = one Controller Map. The `name` property becomes the device name in the ossia score Device Explorer.

### Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `name` | `string` | **yes** | — | Device name. Becomes the tree root: `"X-Touch"` → `X-Touch:/`. |
| `vendor` | `string` | no | `""` | Manufacturer name. Metadata only. |
| `model` | `string` | no | `""` | Model name. Metadata only. |
| `author` | `string` | no | `""` | Script author. Metadata only. |
| `version` | `string` | no | `""` | Script version. Metadata only. |
| `endpoint` | `EndpointFilter` | no | `null` | Matching criteria for auto-detection. See §5. **When omitted**, the map is a generic controller that the user manually assigns to a MIDI Endpoint in ossia score's device setup UI. |
| `init` | `list<SysEx\|Delay>` | no | `[]` | Messages sent after Endpoint connect. See §6. |
| `deinit` | `list<SysEx\|Delay>` | no | `[]` | Messages sent before Endpoint disconnect. See §6. |
| `tree` | `list<Node\|Parameter>` | **yes** | — | The device tree. See §7. |
| `layers` | `list<Layer>` | no | `[]` | Mapping pages / modes. See §13. |
| `script` | `Script` | no | `null` | Imperative escape hatch. See §16. |
| `profiles` | `list<Profile>` | no | `[]` | MIDI 2.0 Profile declarations. See §19. |
| `autoDiscoverParameters` | `bool` | no | `false` | If `true`, C++ queries the Endpoint for PE `ChCtrlList`. |
| `endpoints` | `list<Endpoint>` | no | `[]` | For multi-device setups. Overrides the singular `endpoint`. See §20. |

User-defined `property` declarations (e.g. `property int bank: 0`) are allowed for reactive state.

### Signals

| Signal | Parameters | Description |
|--------|------------|-------------|
| `onParametersDiscovered(controls)` | `controls: Array<{index, name, min, max, default, priority}>` | Fired when PE `ChCtrlList` query completes. |

### Generic vs. Specific Device Matching

There are two modes:

**Specific device** — `endpoint` is set with an `EndpointFilter`. C++ auto-matches the map to the first connected Endpoint that satisfies the filter. If multiple Endpoints match, each gets its own instance of the map.

**Generic / manual assignment** — `endpoint` is omitted. The map appears in ossia score's device setup as a Controller Map type. The user creates a device instance and selects the physical MIDI Endpoint from a dropdown list. This is the workflow for cheap/unknown controllers, or when the user has multiple identical devices and needs to assign each manually.

Both modes produce the same device tree. The only difference is how the Endpoint binding is established.

---

## 5. EndpointFilter — Device Matching

C++ uses this to auto-detect which physical UMP Endpoint a Controller Map binds to. Matched against the UMP Endpoint Discovery response (or the SysEx Device Inquiry response for OS-upscaled MIDI 1.0 devices).

### Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `manufacturer` | `int` | **yes** | — | 24-bit SysEx manufacturer ID (e.g. `0x002029` for Novation). |
| `family` | `int` | no | `-1` | 16-bit device family ID. `-1` = match any. |
| `model` | `int` | no | `-1` | 16-bit model ID. `-1` = match any. |
| `softwareRevision` | `int` | no | `-1` | 32-bit software revision. `-1` = match any. |

### Example

```qml
endpoint: EndpointFilter {
    manufacturer: 0x002032   // Behringer
    family:       0x0015     // X-Touch family
}
```

---

## 6. Init and DeInit Sequences

Ordered lists of `SysEx` and `Delay` objects sent by C++ immediately after Endpoint connection (`init`) or before disconnection (`deinit`).

### `SysEx`

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `data` | `list<int>` | **yes** | Payload bytes **without** F0/F7. C++ wraps in UMP SysEx7 and handles chunking. |

### `Delay`

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `ms` | `int` | **yes** | Delay in milliseconds. |

---

## 7. Tree — The Exposed Device Tree

The `tree` property is a list of `Node` and `Parameter` objects that becomes the device tree in ossia's Device Explorer.

The tree is a hierarchy of `Node` objects (namespaces) with `Parameter` objects at the leaves. The `Bank` type (§9) generates repeated children.

---

## 8. Node — Namespace Container

A non-leaf element that groups children under a named path segment.

### Properties

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `name` | `string` | **yes** | Path segment. Must be unique among siblings. Valid characters: `a-z`, `A-Z`, `0-9`, `_`. |
| `children` | `list<Node\|Parameter\|Bank>` | **yes** | Child nodes, parameters, and banks. |

### Example

```qml
Node {
    name: "strip"
    children: [
        Node {
            name: "1"
            children: [
                Parameter { name: "fader"; /* ... */ }
            ]
        }
    ]
}
```

---

## 9. Bank — Repeated Children

`Bank` is a non-visual QML type registered by ossia that generates repeated children. It replaces Qt Quick's `Repeater`, which is unavailable in this scripting environment (no Qt Quick scene graph).

C++ instantiates `count` copies of the `delegate` component, or one copy per entry if `model` is an array. Each instance receives `index` (int) and, when `model` is an array, `modelData` (the array element) as context properties.

### Properties

| Property | Type | Required | Default | Description |
|----------|------|----------|---------|-------------|
| `count` | `int` | no* | `0` | Number of instances to create. Reactive — when the value changes, C++ destroys old children and creates new ones. |
| `model` | `var` (int or array) | no* | `undefined` | Alternative to `count`. If an int, equivalent to `count`. If an array, one instance per element with `modelData` set. Reactive. |
| `delegate` | `Component` | **yes** | — | QML Component to instantiate. Must evaluate to a `Node` or `Parameter`. |

*One of `count` or `model` must be set.

### Context Properties Injected into Each Delegate Instance

| Property | Type | Description |
|----------|------|-------------|
| `index` | `int` | Zero-based index of this instance (0, 1, 2, ...). |
| `modelData` | `var` | When `model` is an array, the corresponding element. Undefined when using `count`. |

### Usage with `count`

```qml
Node {
    name: "strip"
    children: [
        Bank {
            count: 8
            delegate: Node {
                name: String(index + 1)
                children: [
                    Parameter {
                        name: "fader"
                        type: Ossia.Float; min: 0; max: 1
                        bind: UmpBind {
                            group: 0; channel: 0
                            type: UmpBind.ControlChange
                            index: 33 + index   // CC33..CC40
                        }
                    }
                ]
            }
        }
    ]
}
```

Produces: `strip/1/fader`, `strip/2/fader`, ..., `strip/8/fader`.

### Usage with `model` (array)

```qml
Node {
    name: "param"
    children: [
        Bank {
            model: root.discoveredControls   // array of {index, name, min, max, default}
            delegate: Parameter {
                name: modelData.name.replace(/[^a-zA-Z0-9_]/g, "_")
                type: Ossia.Float
                min: modelData.min; max: modelData.max
                default: modelData.default
                bind: UmpBind {
                    group: 0; channel: 0
                    type: UmpBind.ControlChange
                    index: modelData.index
                }
            }
        }
    ]
}
```

### Reactive Model

When `count` or `model` is bound to a reactive property, C++ destroys all existing children and re-instantiates when the property changes. This is the mechanism for dynamic tree creation (§21).

```qml
property int stripCount: 0   // set by script after SysEx response

Bank {
    count: root.stripCount   // tree rebuilds when stripCount changes
    delegate: Node { /* ... */ }
}
```

### Nesting

Banks can be nested inside Nodes, and Nodes inside Bank delegates. Banks cannot be direct children of other Banks without an intervening Node.

---

## 10. Parameter — Leaf Address

A leaf node that creates an ossia address with a value.

### Core Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `name` | `string` | *required* | Address segment. Unique among siblings. |
| `type` | `enum` | *required* | ossia type: `Ossia.Float`, `Ossia.Int`, `Ossia.Bool`, `Ossia.Impulse`, `Ossia.String`, `Ossia.Vec2f`, `Ossia.Vec3f`, `Ossia.Vec4f`, `Ossia.List`, `Ossia.Color`. |
| `min` | `real\|list` | `0.0` | Minimum value. |
| `max` | `real\|list` | `1.0` | Maximum value. |
| `default` | `any` | `0.0` | Initial value. |
| `unit` | `string` | `""` | ossia unit: `"dB"`, `"Hz"`, `"degree"`, `"linear"`, etc. |
| `description` | `string` | `""` | Human-readable description. |

### UMP Binding

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `bind` | `UmpBind` | `null` | Packet match pattern. See §11. `null` = output-only parameter. |
| `bindX` | `UmpBind` | `null` | X-axis binding for `Vec2f`. |
| `bindY` | `UmpBind` | `null` | Y-axis binding for `Vec2f`. |

### Touch Sensitivity

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `touchBind` | `UmpBind` | `null` | Separate touch sensor binding. Auto-creates `<name>_touch` Bool sibling. See §23. |

### Value Transforms

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `read` | `function(real) → real` | identity | Normalised UMP `[0,1]` → tree parameter value (before min/max scaling). |
| `write` | `function(real) → real` | identity | Reverse: tree value → normalised `[0,1]` (for feedback). |

### Encoder Behaviour

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `encoder` | `Encoder` enum | `Encoder.Off` | Relative mode. See §24. |
| `sensitivity` | `real` | `1.0` | Normalised delta per tick. |
| `acceleration` | `bool` | `false` | Scale delta by turning speed. |

### Soft-Takeover

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `softTakeover` | `Parameter` enum | `Parameter.Off` | See §24. |

### Toggle

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `toggle` | `bool` | `false` | For `Bool`: each press flips value. |

### Stepped Quantisation

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `steps` | `int` | `0` | Discrete positions. `0` = continuous. |

### Button Press Patterns

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `longPressMs` | `int` | `0` | Long-press threshold. `0` = disabled. Auto-creates `<name>_long_press` Impulse sibling. See §23. |
| `doublePressMs` | `int` | `0` | Double-press gap. `0` = disabled. Auto-creates `<name>_double_press` Impulse sibling. See §23. |

### Feedback

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `feedback` | `LedFeedback\|RingLed\|ColorFeedback\|DisplayFeedback` | `null` | See §12. |

### Change Callback

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `onChanged` | `function(value)` | `null` | Called on every value change from any source. |

### Conditional Activation

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `enabled` | `bool` | `true` | Reactive. When `false`, parameter ignores input and doesn't send feedback. |

### Multi-Endpoint

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `endpoint` | `Endpoint` ref | first endpoint | For multi-endpoint setups. See §20. |

---

## 11. UmpBind — Packet Match Pattern

A declarative filter that C++ evaluates against each incoming UMP packet. **Not** a port reference.

### Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `group` | `int` | `0` | UMP Group (0–15). |
| `channel` | `int` | `0` | Channel (0–15). |
| `type` | `UmpBind` enum | *required* | Message type. See below. |
| `index` | `int` | `-1` | CC / controller index (0–32767). `-1` = don't care. |
| `note` | `int` | `-1` | Note number (0–127). `-1` = don't care. |
| `bank` | `int` | `-1` | Controller bank (0–127). `-1` = don't care. |
| `perNoteIndex` | `int` | `-1` | Per-note controller index (0–255). `-1` = don't care. |

### Type Enum

**MIDI 2.0 Channel Voice (UMP MT 0x4):**
`NoteOn`, `NoteOff`, `PolyPressure`, `ControlChange`, `ProgramChange`, `ChannelPressure`, `PitchBend`, `PerNoteCC`, `PerNotePitchBend`, `PerNoteManagement`, `RegisteredController`, `AssignableController`, `RelRegisteredController`, `RelAssignableController`.

**System (UMP MT 0x1):**
`TimingClock`, `Start`, `Continue`, `Stop`, `ActiveSensing`, `SystemReset`, `MidiTimeCode`, `SongPositionPointer`, `SongSelect`, `TuneRequest`.

**Data (UMP MT 0x3/0x5):**
`SysEx7`, `SysEx8`.

### C++ Matching Pseudocode

```cpp
for (auto& param : map.allParameters()) {
    if (!param.enabled) continue;
    auto& b = param.bind;
    if (!b) continue;
    if (packet.group()   != b.group)   continue;
    if (packet.channel() != b.channel) continue;
    if (packet.status()  != b.type)    continue;
    if (b.index >= 0 && packet.controlIndex() != b.index) continue;
    if (b.note  >= 0 && packet.noteNumber()   != b.note)  continue;
    if (b.bank  >= 0 && packet.bank()         != b.bank)  continue;
    if (b.perNoteIndex >= 0 && packet.perNoteIndex() != b.perNoteIndex) continue;

    float norm = normalise(packet);     // 32-bit → [0,1] or [-1,1]
    float val  = param.read(norm);      // QML transform
    val = param.scaleToRange(val);      // [0,1] → [min,max]
    if (param.steps > 0) val = quantise(val, param.steps);
    if (!param.checkSoftTakeover(val)) continue;
    param.setValue(val);
    param.invokeOnChanged(val);
}
// Unmatched packets → Script.onUnhandledUmp()
```

---

## 12. Feedback Types

Feedback sends UMP packets back to the controller when a Parameter's value changes.

### 12.1 `LedFeedback`

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `bind` | `UmpBind` | *required* | UMP message to send. |
| `states` | `list<LedState>` | `[]` | State table. If empty → continuous value echo. |

### 12.2 `LedState`

**For Bool:**

| Property | Type | Description |
|----------|------|-------------|
| `value` | `bool` | Value to match. |
| `velocity` | `real` | Normalised velocity (0.0–1.0). |
| `blinkMs` | `int` | Blink rate. `0` = no blink. |

**For Float (ranged):**

| Property | Type | Description |
|----------|------|-------------|
| `min` | `real` | Lower bound (inclusive). |
| `max` | `real` | Upper bound (exclusive). |
| `velocity` | `real` | Normalised velocity. |
| `blinkMs` | `int` | Blink rate. |

### 12.3 `RingLed`

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `bind` | `UmpBind` | *required* | CC to send. |
| `segments` | `int` | `11` | LED count. |
| `mode` | `RingLed` enum | `RingLed.Dot` | See §24. |

### 12.4 `ColorFeedback`

| Property | Type | Description |
|----------|------|-------------|
| `send` | `function(r, g, b) → list<int>` | Returns SysEx payload (without F0/F7). r/g/b in [0,255]. |

### 12.5 `DisplayFeedback`

| Property | Type | Description |
|----------|------|-------------|
| `send` | `function(text) → list<int>` | Returns SysEx payload. |

---

## 13. Layers

Layers define which mappings are active and can override UMP bindings.

### Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `name` | `string` | *required* | Layer name. |
| `active` | `bool` | `true` | Reactive expression. Layer is active when `true`. |
| `mappings` | `list<Mapping\|Bank>` | `[]` | Address bindings. May use `Bank` for repetition. |
| `rebinds` | `list<Rebind>` | `[]` | Binding overrides. |

---

## 14. Mapping — Address Binding

Connects a tree parameter to an external ossia address.

### Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `from` | `string` | *required* | Path in our tree. |
| `to` | `string` | *required* | Any ossia address. |
| `direction` | `Mapping` enum | `Mapping.Bidirectional` | `.In`, `.Out`, `.Bidirectional`. |
| `sourceMin` | `real` | parameter's `min` | Sub-range of source. |
| `sourceMax` | `real` | parameter's `max` | |
| `targetMin` | `real` | target's `min` | Sub-range of target. |
| `targetMax` | `real` | target's `max` | |
| `transform` | `function(real) → real` | `null` | Overrides range properties. |
| `inverseTransform` | `function(real) → real` | `null` | Required for bidirectional if `transform` is set. |
| `enabled` | `bool` | `true` | Reactive. |

---

## 15. Rebind — Binding Override

Overrides a Parameter's `UmpBind` within a Layer (for bank switching).

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `parameter` | `string` | **yes** | Tree path. |
| `bind` | `UmpBind` | **yes** | Replacement match pattern. |

---

## 16. Script — Imperative Escape Hatch

### Callbacks

| Callback | Parameters | When |
|----------|------------|------|
| `onInit()` | — | After init sequence + Endpoint connected. |
| `onDeInit()` | — | Before deinit sequence. |
| `onUnhandledUmp(packet)` | `packet: UmpPacket` | Incoming UMP not matched by any Parameter. |
| `onIdle()` | — | Periodic (default 100ms). |

### `UmpPacket` (read-only)

| Property | Type | Description |
|----------|------|-------------|
| `type` | `int` | Message type. |
| `group` | `int` | Group (0–15). |
| `channel` | `int` | Channel (0–15). |
| `status` | `int` | Status byte. |
| `data` | `list<int>` | Raw UMP words (32-bit). |

---

## 17. Ump — Packet Factory

Global object in `Script` blocks. All methods construct and send a UMP packet via C++.

| Method | Parameters |
|--------|------------|
| `controlChange(group, ch, index, value32)` | `int, int, int, int` |
| `noteOn(group, ch, note, velocity16, attrType, attrData)` | `int, int, int, int, int, int` |
| `noteOff(group, ch, note, velocity16)` | `int, int, int, int` |
| `pitchBend(group, ch, value32)` | `int, int, int` |
| `channelPressure(group, ch, value32)` | `int, int, int` |
| `polyPressure(group, ch, note, value32)` | `int, int, int, int` |
| `perNoteCC(group, ch, note, index, value32)` | `int, int, int, int, int` |
| `perNotePitchBend(group, ch, note, value32)` | `int, int, int, int` |
| `programChange(group, ch, program, bankValid, bankMsb, bankLsb)` | `int, int, int, bool, int, int` |
| `registeredController(group, ch, bank, index, value32)` | `int, int, int, int, int` |
| `assignableController(group, ch, bank, index, value32)` | `int, int, int, int, int` |
| `sendSysEx7(group, byteArray)` | `int, list<int>` |
| `sendSysEx8(group, streamId, byteArray)` | `int, int, list<int>` |

---

## 18. Tree Helper — Script Access to Parameters

Global object in `Script` blocks.

| Method | Parameters | Returns | Description |
|--------|------------|---------|-------------|
| `Tree.get(path)` | `string` | `any` | Current value at path. |
| `Tree.set(path, value)` | `string, any` | — | Set value. Triggers feedback and `onChanged`. |

Paths are relative to the map root (e.g. `"strip/1/fader"`).

---

## 19. Profiles and Property Exchange

### `Profile`

| Property | Type | Description |
|----------|------|-------------|
| `profileId` | `ProfileId` | Bank + number. |
| `onEnabled` | JS block | Runs when Profile is negotiated on. |
| `onDisabled` | JS block | Runs when Profile is turned off. |

### `ProfileId`

| Property | Type |
|----------|------|
| `bank` | `int` |
| `number` | `int` |

### PE Auto-Discovery

When `autoDiscoverParameters: true`, C++ queries for PE `ChCtrlList` after MIDI-CI handshake and fires `onParametersDiscovered`. See §21 for the pattern.

---

## 20. Multi-Endpoint Composition

### `Endpoint`

| Property | Type | Description |
|----------|------|-------------|
| `id` | QML id | Referenced by `Parameter.endpoint`. |
| `filter` | `EndpointFilter` | Matching criteria. |

When `endpoints` is used, `endpoint` on `ControllerMap` is ignored. Each Parameter can specify `endpoint: <id>`. Default: first Endpoint.

For generic/manual assignment with multiple endpoints, the user assigns each `Endpoint` to a physical port in the device setup UI.

---

## 21. Dynamic Tree Creation

The tree is declarative. Variable topology (e.g. unknown strip count) is handled by binding a `Bank`'s `count` to a reactive property set by the Script.

### Pattern

```qml
ControllerMap {
    property int stripCount: 0

    tree: [
        Node {
            name: "strip"
            children: [
                Bank {
                    count: root.stripCount
                    delegate: Node {
                        name: String(index + 1)
                        children: [ /* ... */ ]
                    }
                }
            ]
        }
    ]

    script: Script {
        function onInit() {
            Ump.sendSysEx7(0, [/* identity request */]);
        }
        function onUnhandledUmp(packet) {
            // Parse response:
            root.stripCount = 8;   // → Bank regenerates 8 children
        }
    }
}
```

### Lifecycle

1. QML loads. `stripCount` = 0. Tree has zero strips.
2. C++ connects Endpoint, sends init sequence.
3. `onInit()` sends SysEx query.
4. Response arrives. `onUnhandledUmp` sets `root.stripCount = 8`.
5. Bank detects model change, C++ instantiates 8 delegates.
6. C++ registers new Parameters in binding table.
7. Tree is populated.

**Constraint:** Topology should stabilise after init. For mode switching that changes what controls *do*, use Layers and Rebinds.

---

## 22. Composability — Reusable QML Components

### `StripParams.qml`

```qml
import Ossia 1.0 as Ossia
import Ossia.Midi 1.0

Node {
    id: strip
    property int idx: 0
    property int faderCC: 0
    property int muteNote: 42

    name: String(idx + 1)
    children: [
        Parameter {
            name: "fader"; type: Ossia.Float; min: 0; max: 1
            bind: UmpBind { group: 0; channel: 0; type: UmpBind.ControlChange; index: strip.faderCC + strip.idx }
            softTakeover: Parameter.Pickup
        },
        Parameter {
            name: "mute"; type: Ossia.Bool; toggle: true
            bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: strip.muteNote + strip.idx }
            feedback: LedFeedback {
                bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: strip.muteNote + strip.idx }
                states: [ LedState { value: false; velocity: 0 }, LedState { value: true; velocity: 1 } ]
            }
        }
    ]
}
```

### Main file

```qml
tree: [
    Node {
        name: "strip"
        children: [
            Bank {
                count: 8
                delegate: StripParams { idx: index }
            }
        ]
    }
]
```

---

## 23. Auto-Created Sibling Parameters

| Trigger | Created sibling | Type | Suffix |
|---------|----------------|------|--------|
| `touchBind` set | `<name>_touch` | `Ossia.Bool` | `_touch` |
| `longPressMs > 0` | `<name>_long_press` | `Ossia.Impulse` | `_long_press` |
| `doublePressMs > 0` | `<name>_double_press` | `Ossia.Impulse` | `_double_press` |

---

## 24. Enumerations Reference

### `Encoder`

| Value | Description |
|-------|-------------|
| `Encoder.Off` | Absolute (default). |
| `Encoder.TwosComplement` | 7F=+1, 01=-1 around 00. |
| `Encoder.SignedBit` | 41=+1, 01=-1 (bit 6 = sign). |
| `Encoder.Offset64` | >64 clockwise, <64 counter-clockwise. |
| `Encoder.RelativeBinaryOffset` | 40=+1, 3F=-1. |

### `Parameter` (soft-takeover)

| Value | Description |
|-------|-------------|
| `Parameter.Off` | No soft-takeover. |
| `Parameter.Pickup` | Ignores until physical crosses software value. |
| `Parameter.ValueScaling` | Gradually catches up. |

### `RingLed`

| Value | Description |
|-------|-------------|
| `RingLed.Dot` | Single LED at position. |
| `RingLed.Bar` | Fill from left to position. |
| `RingLed.Spread` | Spread from center. |
| `RingLed.Trim` | Fill from position to right. |

### `Mapping` (direction)

| Value | Description |
|-------|-------------|
| `Mapping.Bidirectional` | Both ways (default). |
| `Mapping.In` | Tree → target only. |
| `Mapping.Out` | Target → tree only. |

---

## 25. Type Catalogue

```
── Root ──
ControllerMap

── Endpoint ──
Endpoint
EndpointFilter

── Tree ──
Node
Bank
Parameter

── Binding ──
UmpBind

── Feedback ──
LedFeedback
LedState
RingLed
ColorFeedback
DisplayFeedback

── Layers ──
Layer
Mapping
Rebind

── Profiles & PE ──
Profile
ProfileId

── Init ──
SysEx
Delay

── Script ──
Script
Ump                       (global packet factory)
Tree                      (global tree accessor)
UmpPacket                 (read-only incoming packet)

── ossia Value Types ──
Ossia.Float   Ossia.Int     Ossia.Bool    Ossia.Impulse
Ossia.String  Ossia.Vec2f   Ossia.Vec3f   Ossia.Vec4f
Ossia.List    Ossia.Color
```

---

## 26. C++ Responsibilities

| Concern | Owner |
|---------|-------|
| Endpoint enumeration (specific + manual assignment UI) | C++ |
| EndpointFilter matching | C++ |
| Raw UMP packet receive / send | C++ |
| Matching packets against `UmpBind` table | C++ |
| Normalising UMP values to [0,1] or [-1,1] | C++ |
| Invoking QML `read`/`write` transforms | C++ (calling JS) |
| Encoder delta accumulation | C++ |
| Soft-takeover gating | C++ |
| Toggle state machine | C++ |
| Long-press timer | C++ |
| Double-press timer | C++ |
| Touch state tracking | C++ |
| Step quantisation | C++ |
| Writing values into ossia device tree | C++ |
| Auto-creating sibling parameters | C++ |
| Constructing feedback UMP packets | C++ |
| LED blink timers | C++ |
| Ring LED segment computation | C++ |
| SysEx init/deinit transmission | C++ |
| Delay timing in init/deinit | C++ |
| Invoking `onChanged` callbacks | C++ → QML |
| `Bank` delegate instantiation and re-instantiation | C++ |
| Observing reactive property changes | QML engine → C++ |
| Rebuilding binding table on changes | C++ |
| Layer activation/deactivation | C++ |
| Rebind application | C++ |
| Range mapping in `Mapping` | C++ |
| Invoking `Mapping.transform`/`inverseTransform` | C++ (calling JS) |
| `onIdle` scheduling (100ms default) | C++ |
| `onUnhandledUmp` dispatch | C++ |
| `Ump.*` send functions | C++ |
| `Tree.get`/`Tree.set` | C++ |
| PE `ChCtrlList` query + `onParametersDiscovered` | C++ |
| MIDI-CI Profile negotiation | C++ |
| Manual Endpoint assignment UI | ossia score UI |

---

## 27. Complete Example — Behringer X-Touch (MCU)

```qml
import Ossia 1.0 as Ossia
import Ossia.Midi 1.0

Ossia.Midi.ControllerMap {
    id: root
    name: "X-Touch"
    vendor: "Behringer"
    model: "X-Touch"
    version: "1.0.0"

    endpoint: EndpointFilter {
        manufacturer: 0x002032
        family: 0x0015
    }

    init: [
        SysEx { data: [0x00, 0x00, 0x66, 0x14, 0x00] }
    ]

    property bool shiftHeld: false
    property int  bank: 0

    tree: [
        // ──── Channel Strips ────
        Node {
            name: "strip"
            children: [
                Bank {
                    count: 8
                    delegate: Node {
                        name: String(index + 1)
                        children: [
                            Parameter {
                                name: "fader"
                                type: Ossia.Float; min: 0; max: 1
                                bind: UmpBind { group: 0; channel: index; type: UmpBind.PitchBend }
                                touchBind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 104 + index }
                                feedback: LedFeedback {
                                    bind: UmpBind { group: 0; channel: index; type: UmpBind.PitchBend }
                                }
                            },
                            Parameter {
                                name: "vpot"
                                type: Ossia.Float; min: 0; max: 1
                                bind: UmpBind { group: 0; channel: 0; type: UmpBind.ControlChange; index: 16 + index }
                                encoder: Encoder.SignedBit
                                sensitivity: 0.02
                                acceleration: true
                                feedback: RingLed {
                                    bind: UmpBind { group: 0; channel: 0; type: UmpBind.ControlChange; index: 48 + index }
                                    segments: 11; mode: RingLed.Dot
                                }
                            },
                            Parameter {
                                name: "select"
                                type: Ossia.Bool; toggle: true
                                bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 24 + index }
                                feedback: LedFeedback {
                                    bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 24 + index }
                                    states: [ LedState { value: false; velocity: 0 }, LedState { value: true; velocity: 1 } ]
                                }
                            },
                            Parameter {
                                name: "mute"
                                type: Ossia.Bool; toggle: true
                                bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 16 + index }
                                longPressMs: 500
                                feedback: LedFeedback {
                                    bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 16 + index }
                                    states: [ LedState { value: false; velocity: 0 }, LedState { value: true; velocity: 1 } ]
                                }
                            },
                            Parameter {
                                name: "solo"
                                type: Ossia.Bool; toggle: true
                                bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 8 + index }
                                feedback: LedFeedback {
                                    bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 8 + index }
                                    states: [ LedState { value: false; velocity: 0 }, LedState { value: true; velocity: 1 } ]
                                }
                            },
                            Parameter {
                                name: "rec"
                                type: Ossia.Bool; toggle: true
                                bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 0 + index }
                                feedback: LedFeedback {
                                    bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 0 + index }
                                    states: [ LedState { value: false; velocity: 0 }, LedState { value: true; velocity: 1 } ]
                                }
                            },
                            Parameter {
                                name: "display"
                                type: Ossia.String; default: ""
                                feedback: DisplayFeedback {
                                    send: function(text) {
                                        var offset = index * 7;
                                        var payload = [0x00, 0x00, 0x66, 0x14, 0x12, offset];
                                        for (var i = 0; i < 7; i++)
                                            payload.push(i < text.length ? text.charCodeAt(i) : 0x20);
                                        return payload;
                                    }
                                }
                            },
                            Parameter {
                                name: "meter"
                                type: Ossia.Float; min: 0; max: 1
                                feedback: LedFeedback {
                                    bind: UmpBind { group: 0; channel: index; type: UmpBind.ChannelPressure }
                                }
                            }
                        ]
                    }
                }
            ]
        },

        // ──── Transport ────
        Node {
            name: "transport"
            children: [
                Parameter { name: "play"; type: Ossia.Bool; toggle: true; bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 94 }
                    feedback: LedFeedback { bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 94 }
                        states: [ LedState { value: false; velocity: 0 }, LedState { value: true; velocity: 1 } ] } },
                Parameter { name: "stop"; type: Ossia.Impulse; bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 93 } },
                Parameter { name: "record"; type: Ossia.Bool; toggle: true; bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 95 }
                    feedback: LedFeedback { bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 95 }
                        states: [ LedState { value: false; velocity: 0 }, LedState { value: true; velocity: 1 } ] } },
                Parameter { name: "rewind"; type: Ossia.Bool; bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 91 } },
                Parameter { name: "forward"; type: Ossia.Bool; bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 92 } },
                Parameter { name: "cycle"; type: Ossia.Bool; toggle: true; bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 86 } }
            ]
        },

        // ──── Jog ────
        Node {
            name: "jog"
            children: [
                Parameter {
                    name: "wheel"
                    type: Ossia.Float; min: 0; max: 1
                    bind: UmpBind { group: 0; channel: 0; type: UmpBind.ControlChange; index: 60 }
                    encoder: Encoder.SignedBit; sensitivity: 0.01; acceleration: true
                }
            ]
        },

        // ──── Navigation ────
        Node {
            name: "nav"
            children: [
                Parameter { name: "bank_left"; type: Ossia.Impulse; bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 46 }
                    onChanged: function() { root.bank = Math.max(0, root.bank - 1) } },
                Parameter { name: "bank_right"; type: Ossia.Impulse; bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 47 }
                    onChanged: function() { root.bank = root.bank + 1 } }
            ]
        },

        // ──── Modifier ────
        Node {
            name: "modifier"
            children: [
                Parameter {
                    name: "shift"
                    type: Ossia.Bool
                    bind: UmpBind { group: 0; channel: 0; type: UmpBind.NoteOn; note: 70 }
                    toggle: false
                    onChanged: function(v) { root.shiftHeld = v }
                }
            ]
        }
    ]

    // ──── Layers ────
    layers: [
        Layer {
            name: "Normal"
            active: !root.shiftHeld
            mappings: [
                Mapping { from: "transport/play"; to: "local:/transport/play" },
                Mapping { from: "transport/stop"; to: "local:/transport/stop" },
                Mapping { from: "transport/record"; to: "local:/transport/record" },
                Bank {
                    count: 8
                    delegate: Mapping {
                        from: "strip/" + (index + 1) + "/vpot"
                        to: "osc:/mixer/" + (root.bank * 8 + index + 1) + "/pan"
                    }
                }
            ]
        },
        Layer {
            name: "Shifted"
            active: root.shiftHeld
            mappings: [
                Bank {
                    count: 8
                    delegate: Mapping {
                        from: "strip/" + (index + 1) + "/vpot"
                        to: "osc:/mixer/" + (root.bank * 8 + index + 1) + "/send_a"
                    }
                }
            ]
        }
    ]

    // ──── Script ────
    script: Script {
        function onInit() {
            for (var i = 0; i < 8; i++)
                Tree.set("strip/" + (i + 1) + "/display", "Ch " + (root.bank * 8 + i + 1));
        }
        function onIdle() { }
        function onUnhandledUmp(packet) { }
        function onDeInit() { }
    }
}
```

---

*End of specification.*
