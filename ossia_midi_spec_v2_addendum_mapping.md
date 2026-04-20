# ossia score — QML MIDI Controller Map API

## Addendum to Specification v2.0: Mapping Address Resolution

---

### Updated §14 — Mapping Address Resolution Rules

The `to` field of a `Mapping` uses the following resolution rules:

**Rule 1 — External device address.** If `to` contains `:/`, it is interpreted as a fully-qualified ossia address on another device. C++ resolves it against the global device tree.

```qml
Mapping { from: "strip/1/fader"; to: "osc:/mixer/1/volume" }
//                                    ^^^^^
//                              device separator — external
```

**Rule 2 — Internal node creation.** If `to` does **not** contain `:/`, it is interpreted as a path relative to the Controller Map's own device root. C++ creates the target node (and any intermediate namespace nodes) under the map's device if they don't already exist. The created node inherits its type, range, and unit from the source parameter.

```qml
Mapping { from: "strip/1/fader"; to: "mix/volume/1" }
//                                    ^^^^^^^^^^^^
//                              no device separator — creates X-Touch:/mix/volume/1
```

This allows Layers to build an **alternative view** of the controller's tree — a user-facing semantic hierarchy separate from the hardware-matching structure, or a simplified alias layer.

**Rule 3 — Internal cross-wiring.** If `to` is a path that already exists in the map's tree (because it was declared in the `tree` property), the Mapping connects the two parameters within the same device. The value of `from` drives the value of `to` (and vice versa for `Bidirectional`).

```qml
Mapping { from: "strip/1/vpot"; to: "strip/1/fader" }
//  links two existing parameters within the same device
```

### Address resolution pseudocode (C++)

```cpp
void resolveMapping(Mapping& m, ControllerMap& map) {
    // Source: always relative to our tree
    m.sourceParam = map.findParameter(m.from);

    if (m.to.contains(":/")) {
        // Rule 1: external device address
        m.targetParam = ossia::global_tree.find(m.to);
    } else {
        // Rule 2 or 3: relative to our device root
        m.targetParam = map.findParameter(m.to);
        if (!m.targetParam) {
            // Rule 2: doesn't exist yet — create it
            m.targetParam = map.createParameter(m.to, m.sourceParam->type(),
                                                 m.sourceParam->range());
        }
    }
}
```

### Practical example: semantic alias layer

A controller map might expose raw hardware bindings in the tree and then use Layers to create a user-friendly top-level structure:

```qml
Ossia.Midi.ControllerMap {
    name: "MyController"

    tree: [
        // Hardware-matching tree (mirrors the physical layout)
        Node {
            name: "hw"
            children: [
                Bank {
                    count: 8
                    delegate: Node {
                        name: String(index + 1)
                        children: [
                            Parameter {
                                name: "cc"
                                type: Ossia.Float; min: 0; max: 1
                                bind: UmpBind {
                                    group: 0; channel: 0
                                    type: UmpBind.ControlChange
                                    index: 1 + index
                                }
                            }
                        ]
                    }
                }
            ]
        }
    ]

    layers: [
        Layer {
            name: "Mixer"
            active: true
            mappings: [
                // These create MyController:/mixer/ch/1/volume, etc.
                // as new nodes in our own device tree.
                Bank {
                    count: 4
                    delegate: Mapping {
                        from: "hw/" + (index + 1) + "/cc"
                        to:   "mixer/ch/" + (index + 1) + "/volume"
                    }
                },
                Bank {
                    count: 4
                    delegate: Mapping {
                        from: "hw/" + (5 + index) + "/cc"
                        to:   "mixer/ch/" + (index + 1) + "/pan"
                    }
                }
            ]
        }
    ]
}
```

Resulting tree:

```
MyController:/
  hw/
    1/cc          Float [0, 1]     ← bound to CC1
    2/cc          Float [0, 1]     ← bound to CC2
    ...
    8/cc          Float [0, 1]     ← bound to CC8
  mixer/
    ch/
      1/
        volume    Float [0, 1]     ← auto-created, driven by hw/1/cc
        pan       Float [0, 1]     ← auto-created, driven by hw/5/cc
      2/
        volume    Float [0, 1]     ← auto-created, driven by hw/2/cc
        pan       Float [0, 1]     ← auto-created, driven by hw/6/cc
      3/
        volume    ...
        pan       ...
      4/
        volume    ...
        pan       ...
```

The user sees both the raw `hw/` tree and the semantic `mixer/` tree. They can wire cables to either. When a different Layer activates (e.g. a "Device" layer), the `mixer/` nodes could be remapped to different source parameters, or new semantic nodes like `device/param/1` could be created.

### Layer deactivation behaviour

When a Layer that created internal nodes deactivates:

- The auto-created nodes **remain in the tree** (they don't disappear). This prevents dangling cables.
- The **mapping connection** is severed: the auto-created node stops being driven by the `from` parameter and retains its last value.
- When the Layer reactivates, the connection is re-established.

This is consistent with how ossia handles parameter lifecycle — parameters are persistent once created within a session.

### Updated Mapping properties table

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `from` | `string` | *required* | Path in our tree (always relative to map root). |
| `to` | `string` | *required* | If contains `:/` → external device address. Otherwise → path relative to map root; auto-created if it doesn't exist. |
| `direction` | `Mapping` enum | `Mapping.Bidirectional` | `.In`, `.Out`, `.Bidirectional`. |
| `sourceMin` | `real` | source's `min` | Sub-range of source. |
| `sourceMax` | `real` | source's `max` | |
| `targetMin` | `real` | target's `min` | Sub-range of target. |
| `targetMax` | `real` | target's `max` | |
| `transform` | `function(real) → real` | `null` | Overrides range properties. |
| `inverseTransform` | `function(real) → real` | `null` | Required for bidirectional if `transform` set. |
| `enabled` | `bool` | `true` | Reactive. |

### Updated C++ responsibilities

| New concern | Owner |
|-------------|-------|
| Parsing `to` for `:/` separator to determine internal vs. external | C++ |
| Auto-creating internal nodes (and intermediate namespaces) | C++ |
| Inheriting type/range from source parameter for auto-created nodes | C++ |
| Maintaining auto-created nodes when Layer deactivates | C++ |
| Severing/re-establishing mapping connection on Layer toggle | C++ |
