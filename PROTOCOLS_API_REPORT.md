# Ossia Score Mapper — `Protocols` API Reference Report

> **Purpose:** This document is a complete reference for another Claude instance to create ossia score mapper scripts that connect MIDI controllers to ossia scenario parameters. It is derived from analysis of `testsJM/` mapper scripts.

---

## 1. Mapper File Structure

Every mapper is a QML file:

```qml
import Ossia 1.0 as Ossia

Ossia.Mapper
{
  // Properties hold open connections (sockets, servers…)
  property var myConnection: null

  // Component.onCompleted runs once after initialization
  Component.onCompleted: {
    console.log("Mapper started");
  }

  // createTree() defines the ossia parameter tree exposed by this mapper device
  function createTree() {
    return [
      {
        name: "my_param",
        type: Ossia.Type.Float,
        value: 0.0,
        write: function(v) { /* called when score writes this param */ },
        read:  function()  { /* called by polling at 'interval' ms */ },
        interval: 1000     // optional polling interval in ms
      }
    ];
  }
}
```

### Node fields summary

| Field      | Required | Description |
|------------|----------|-------------|
| `name`     | yes      | Node name (becomes OSC-like path segment) |
| `type`     | yes      | `Ossia.Type.{String,Int,Float,Bool,List}` |
| `value`    | no       | Initial/default value |
| `write`    | no       | Called when score writes the parameter; receives `v` where `v.value` is the new value |
| `read`     | no       | Called periodically; use with `interval` |
| `interval` | no       | Polling period in ms for `read` |

### Device API (read/write the tree from JS)

```js
Device.write("/path/to/param", value);   // push a value into the tree
Device.read("/path/to/param");           // pull current value
```

Paths start with `/` and match `name` fields in the tree.

---

## 2. `Protocols` API — Complete Reference

`Protocols` is a global QML singleton injected into every mapper.

---

### 2.1 MIDI (Legacy / MIDI 1.0)

#### Enumerate devices

```js
var inputs  = Protocols.inboundMIDIDevices();   // returns Array of device descriptors
var outputs = Protocols.outboundMIDIDevices();  // same for outputs
```

Each element is a plain object — pass it directly as `Transport`.

#### Open MIDI Input

```js
var midiIn = Protocols.inboundMIDI({
  Transport: inputs[0],
  onOpen:    function(socket) { /* connection ready */ },
  onClose:   function()       { /* connection closed */ },
  onError:   function(err)    { /* error string */ },
  onMessage: function(msg) {
    // msg.bytes     — Array of integers (raw MIDI bytes)
    // msg.timestamp — Number (time in ms)
    var status = msg.bytes[0];  // e.g. 0xB0 = CC on channel 1
    var data1  = msg.bytes[1];  // CC number or note
    var data2  = msg.bytes[2];  // CC value or velocity
  }
});
```

#### Open MIDI Output

```js
var midiOut = Protocols.outboundMIDI({
  Transport: outputs[0],
  onOpen:  function(socket) { },
  onClose: function()       { },
  onError: function(err)    { }
});

// midiOut methods (call after onOpen fires):
midiOut.sendNoteOn(channel, note, velocity);          // channel 0-15
midiOut.sendNoteOff(channel, note, velocity);
midiOut.sendControlChange(channel, controller, value); // value 0-127
midiOut.sendProgramChange(channel, program);
midiOut.sendMessage([0xB0, 7, 100]);                   // raw bytes array
```

#### Typical MIDI CC → ossia parameter mapping pattern

```qml
import Ossia 1.0 as Ossia

Ossia.Mapper
{
  property var devices: Protocols.inboundMIDIDevices()
  property var midiIn: devices.length > 0
    ? Protocols.inboundMIDI({
        Transport: devices[0],
        onMessage: function(msg) {
          var status = msg.bytes[0] & 0xF0;  // strip channel
          var ch     = msg.bytes[0] & 0x0F;
          if(status === 0xB0) {              // Control Change
            var cc  = msg.bytes[1];
            var val = msg.bytes[2] / 127.0;  // normalize to 0..1
            Device.write("/cc/" + cc, val);
          }
          if(status === 0x90 && msg.bytes[2] > 0) {   // Note On
            Device.write("/note/" + msg.bytes[1], msg.bytes[2] / 127.0);
          }
        }
      })
    : null

  function createTree() {
    var nodes = [
      { name: "status", type: Ossia.Type.String,
        value: devices.length > 0 ? "open" : "no_device" }
    ];
    // Generate CC nodes 0-127
    var cc = { name: "cc", type: Ossia.Type.List, value: [] };
    // Or individual nodes:
    for(var i = 0; i < 128; i++) {
      nodes.push({ name: "cc_" + i, type: Ossia.Type.Float, value: 0.0 });
    }
    return nodes;
  }
}
```

---

### 2.2 UMP (MIDI 2.0 — Universal MIDI Packet)

```js
var inputs  = Protocols.inboundUMPDevices();
var outputs = Protocols.outboundUMPDevices();

var umpIn = Protocols.inboundUMP({
  Transport: inputs[0],
  onOpen:    function(socket) { },
  onClose:   function()       { },
  onError:   function(err)    { },
  onMessage: function(msg) {
    // msg.words     — Array of 4 × uint32 (UMP packet)
    // msg.timestamp — Number
  }
});

var umpOut = Protocols.outboundUMP({
  Transport: outputs[0],
  onOpen:  function(socket) { },
  onClose: function()       { },
  onError: function(err)    { }
});

// umpOut methods:
umpOut.sendNoteOn(group, channel, note, velocity, attrType, attr);
umpOut.sendNoteOff(group, channel, note, velocity, attrType, attr);
umpOut.sendControlChange(group, channel, controller, value);
umpOut.sendMessage([word0, word1, word2, word3]); // 4 uint32 words
```

---

### 2.3 UDP

#### Inbound (receive)

```js
var udpIn = Protocols.inboundUDP({
  Transport: { Bind: "0.0.0.0", Port: 9001 },
  onOpen:    function(socket) { },
  onClose:   function()       { },
  onError:   function()       { },
  onMessage: function(bytes, sender) {
    // bytes  — raw Uint8Array / byte string
    // sender — optional: { host: "1.2.3.4", port: 5678, reply: function(data) }
    var str = bytes.toString();
    sender.reply("pong");  // send back to the source address
  }
});
```

#### Outbound (send)

```js
var udpOut = Protocols.outboundUDP({
  Transport: { Host: "127.0.0.1", Port: 9001 },
  onOpen:  function(socket) { socket.write("hello"); },
  onClose: function()       { },
  onError: function()       { }
});

// After open:
udpOut.write("raw text or bytes");
udpOut.osc("/address", [value1, value2]);  // encode as OSC and send
```

---

### 2.4 TCP

#### Inbound (server)

```js
var server = Protocols.inboundTCP({
  Transport: { Bind: "0.0.0.0", Port: 5000 },
  Framing:   { type: "line", delimiter: "\r\n" },  // optional
  Encoding:  { type: "base64" },                    // optional
  onOpen: function() { /* server listening */ },
  onConnection: function(socket) {
    // called for each new client
    socket.onClose = function() { /* client disconnected */ };
    socket.receive(function(data) {
      var text = data.toString();
      socket.write("echo:" + text);  // reply to this client
    });
  },
  onClose: function() { }
});
```

#### Outbound (client)

```js
var client = Protocols.outboundTCP({
  Transport: { Host: "127.0.0.1", Port: 5000 },
  Framing:   { type: "slip" },   // optional
  onOpen: function(socket) {
    socket.write("hello");
  },
  onMessage: function(data) { /* data received from server */ },
  onClose: function()        { },
  onFail:  function()        { /* connection refused / timeout */ }
});
```

#### Framing options

| `type`         | Description |
|----------------|-------------|
| `"line"`       | Newline-delimited. Optional `delimiter` key (default `"\n"`). Common for text protocols. |
| `"slip"`       | SLIP packet framing. Good for binary/OSC over serial-style TCP. |
| `"size_prefix"`| 4-byte big-endian length prefix per message. |
| (none)         | Raw stream — `receive()` gives whatever bytes arrive. |

#### Encoding options (orthogonal to Framing)

| `type`       | Description |
|--------------|-------------|
| `"base64"`   | Encode/decode payload as Base64. |
| `"hex"`      | Encode/decode as uppercase hex string. |
| `"ascii85"`  | ASCII85 / Base85 encoding. |
| `"intel_hex"`| Intel HEX record format. |
| `"srec"`     | Motorola SREC format. |

---

### 2.5 WebSocket

#### Server (inbound)

```js
var wsServer = Protocols.inboundWS({
  Transport: { Bind: "0.0.0.0", Port: 8080 },
  onOpen:       function(socket) { /* server bound */ },
  onClose:      function()       { },
  onError:      function()       { },
  onConnection: function(socket) { /* new client socket */ }
});
```

#### Client (outbound)

```js
var ws = Protocols.outboundWS({
  Transport: { Host: "127.0.0.1", Port: 8080 },
  onOpen:          function(socket) { socket.write("hello"); },
  onClose:         function()       { },
  onError:         function()       { },
  onTextMessage:   function(msg)    { /* string message from server */ },
  onBinaryMessage: function(msg)    { /* binary message from server */ }
});

ws.write("text message");
ws.writeBinary(bytes);
```

---

### 2.6 HTTP

Two call signatures:

#### Simple form (legacy)

```js
Protocols.http(url, callback, verb);
// callback receives: function(responseBody)  — body as string, no status code
```

#### Object form (recommended)

```js
Protocols.http({
  url:        "http://host/path",
  verb:       "GET",      // GET | POST | PUT | DELETE | PATCH | HEAD
  headers:    { "Content-Type": "application/json", "Authorization": "Bearer TOKEN" },
  body:       '{"key":"value"}',   // string body for POST/PUT/PATCH
  onResponse: function(statusCode, body) { /* all HTTP status codes land here */ },
  onError:    function(errorString)      { /* network/timeout errors */ }
});
```

---

### 2.7 OSC Parser

For decoding OSC from raw bytes (e.g., UDP payloads):

```js
var osc = Protocols.osc({
  onOsc: function(address, args) {
    // address — string, e.g. "/my/param"
    // args    — Array of values
  }
});

// Feed raw bytes into the parser:
osc.processMessage(rawBytes);
```

OSC encoding on a UDP socket is handled by `socket.osc(address, argsArray)`.

---

### 2.8 Unix Sockets (local IPC)

```js
// Datagram (like UDP, local only)
Protocols.inboundUnixDatagram({ Transport: { Path: "/tmp/my.sock" }, onMessage: ... })
Protocols.outboundUnixDatagram({ Transport: { Path: "/tmp/my.sock" } })

// Stream (like TCP, local only)
Protocols.inboundUnixStream({ Transport: { Path: "/tmp/my.sock" }, onConnection: ... })
Protocols.outboundUnixStream({ Transport: { Path: "/tmp/my.sock" }, onOpen: ... })
```

---

## 3. MIDI Controller → Ossia Scenario: Design Patterns

### 3.1 CC Knob/Fader → normalized float parameter

```qml
// Receives CC #7 (volume) and maps to /scenario/param
onMessage: function(msg) {
  if((msg.bytes[0] & 0xF0) === 0xB0) {   // CC on any channel
    var cc  = msg.bytes[1];
    var val = msg.bytes[2] / 127.0;
    if(cc === 7) Device.write("/scenario/param", val);
  }
}
```

### 3.2 Note On/Off → boolean trigger

```qml
onMessage: function(msg) {
  var status = msg.bytes[0] & 0xF0;
  var note   = msg.bytes[1];
  if(status === 0x90 && msg.bytes[2] > 0) Device.write("/triggers/" + note, true);
  if(status === 0x80 || (status === 0x90 && msg.bytes[2] === 0))
    Device.write("/triggers/" + note, false);
}
```

### 3.3 Pitch Bend → float (-1.0 to +1.0)

```qml
onMessage: function(msg) {
  if((msg.bytes[0] & 0xF0) === 0xE0) {
    var raw = (msg.bytes[2] << 7) | msg.bytes[1];   // 0..16383
    var val = (raw - 8192) / 8192.0;               // -1..+1
    Device.write("/pitch_bend", val);
  }
}
```

### 3.4 Poly Aftertouch → float per note

```qml
onMessage: function(msg) {
  if((msg.bytes[0] & 0xF0) === 0xA0) {
    Device.write("/aftertouch/" + msg.bytes[1], msg.bytes[2] / 127.0);
  }
}
```

### 3.5 Multi-channel routing

```qml
onMessage: function(msg) {
  var status  = msg.bytes[0] & 0xF0;
  var channel = msg.bytes[0] & 0x0F;   // 0..15
  if(status === 0xB0) {
    Device.write("/ch" + channel + "/cc/" + msg.bytes[1],
                 msg.bytes[2] / 127.0);
  }
}
```

### 3.6 Full MIDI controller mapper template

```qml
import Ossia 1.0 as Ossia

Ossia.Mapper
{
  property var devices: Protocols.inboundMIDIDevices()

  property var midiIn: devices.length > 0
    ? Protocols.inboundMIDI({
        Transport: devices[0],
        onOpen: function() {
          Device.write("/status", "connected");
          Device.write("/device_name", JSON.stringify(devices[0]));
        },
        onClose: function() { Device.write("/status", "disconnected"); },
        onError: function(e) { Device.write("/status", "error:" + e); },
        onMessage: function(msg) {
          var status  = msg.bytes[0] & 0xF0;
          var channel = msg.bytes[0] & 0x0F;
          var d1 = msg.bytes[1];
          var d2 = msg.bytes.length > 2 ? msg.bytes[2] : 0;

          // Control Change
          if(status === 0xB0)
            Device.write("/cc/" + d1, d2 / 127.0);

          // Note On
          if(status === 0x90 && d2 > 0)
            Device.write("/note/" + d1, d2 / 127.0);

          // Note Off (also Note-On with vel 0)
          if(status === 0x80 || (status === 0x90 && d2 === 0))
            Device.write("/note/" + d1, 0.0);

          // Pitch Bend
          if(status === 0xE0) {
            var raw = (d2 << 7) | d1;
            Device.write("/pitch_bend", (raw - 8192) / 8192.0);
          }

          // Program Change
          if(status === 0xC0)
            Device.write("/program", d1);
        }
      })
    : null

  function createTree() {
    var nodes = [
      { name: "status",      type: Ossia.Type.String, value: "idle" },
      { name: "device_name", type: Ossia.Type.String, value: "" },
      { name: "pitch_bend",  type: Ossia.Type.Float,  value: 0.0 },
      { name: "program",     type: Ossia.Type.Int,    value: 0 }
    ];

    // CC nodes 0–127
    var ccNodes = [];
    for(var cc = 0; cc < 128; cc++)
      ccNodes.push({ name: "" + cc, type: Ossia.Type.Float, value: 0.0 });
    nodes.push({ name: "cc", type: Ossia.Type.List, value: ccNodes });

    // Note nodes 0–127
    var noteNodes = [];
    for(var n = 0; n < 128; n++)
      noteNodes.push({ name: "" + n, type: Ossia.Type.Float, value: 0.0 });
    nodes.push({ name: "note", type: Ossia.Type.List, value: noteNodes });

    return nodes;
  }
}
```

---

## 4. Device Tree Node Types

| Type                | JS type    | Notes |
|---------------------|------------|-------|
| `Ossia.Type.Float`  | number     | 32-bit float |
| `Ossia.Type.Int`    | number     | 32-bit integer |
| `Ossia.Type.String` | string     | UTF-8 |
| `Ossia.Type.Bool`   | boolean    | true/false |
| `Ossia.Type.List`   | array      | Heterogeneous list; `v.value` is array of `{value: x}` objects |

For `List` write callbacks, individual elements are accessed as:
```js
write: function(v) {
  var first = v.value[0].value;  // unwrap each element
}
```

---

## 5. Key Behaviors and Constraints

1. **Connections are live properties.** Assign them to `property var` at the top level of `Ossia.Mapper`. If the property goes out of scope, the connection closes.

2. **`createTree()` is called once.** The returned array is static — you cannot add nodes dynamically after initialization. Design the full tree upfront.

3. **`write` functions receive `v`, not bare values.** Always use `v.value` to access the incoming value.

4. **`Device.read()` may return `undefined`** if the path does not exist yet. Guard with `|| defaultValue`.

5. **`Component.onCompleted`** is the safe place to run initialization code that depends on the tree being built.

6. **MIDI device descriptors** are opaque objects — pass them directly as `Transport`, do not attempt to read their fields for anything other than display.

7. **MIDI channel is encoded in the status byte.** `msg.bytes[0] & 0x0F` gives 0-based channel (0–15). `msg.bytes[0] & 0xF0` gives the message type.

8. **All protocol callbacks run on the main Qt event loop** — no threading concerns, but avoid blocking calls.

9. **`Framing` and `Encoding` on TCP are independent layers.** You can combine them: `Framing: {type:"line"}` + `Encoding: {type:"base64"}` sends base64-encoded lines.

10. **`udpOut.osc(address, args)`** constructs and sends a complete OSC bundle. `Protocols.osc({onOsc})` only parses; it does not send.

---

## 6. Available Test Files for Reference

All test files are in `/Users/bltzr/dev/AI-score-mappers/testsJM/`:

| File | Protocol/Pattern |
|------|-----------------|
| `test_midi_inbound.qml`       | MIDI 1.0 receive, enumerate devices |
| `test_midi_outbound.qml`      | MIDI 1.0 send: noteOn/Off, CC, PC, raw |
| `test_ump_inbound.qml`        | MIDI 2.0 UMP receive |
| `test_ump_outbound.qml`       | MIDI 2.0 UMP send |
| `test_osc_udp.qml`            | OSC over UDP (parser + send) |
| `test_udp_inbound.qml`        | UDP receive |
| `test_udp_outbound.qml`       | UDP send with OSC helper |
| `test_udp_reply.qml`          | UDP reply to sender |
| `test_tcp_loopback.qml`       | TCP server+client in one mapper |
| `test_tcp_inbound.qml`        | TCP server with broadcast |
| `test_tcp_outbound.qml`       | TCP client |
| `test_tcp_line_loopback.qml`  | Line-framed TCP |
| `test_tcp_slip_loopback.qml`  | SLIP-framed TCP |
| `test_tcp_size_prefix_*.qml`  | Size-prefix framed TCP |
| `test_tcp_base64_loopback.qml`| Base64-encoded TCP |
| `test_tcp_hex_loopback.qml`   | Hex-encoded TCP |
| `test_ws_inbound.qml`         | WebSocket server |
| `test_ws_outbound.qml`        | WebSocket client |
| `test_http.qml`               | HTTP simple form |
| `test_http_get.qml`           | HTTP GET with status codes |
| `test_http_post_json.qml`     | HTTP POST/PUT/DELETE with JSON |
| `test_http_bearer_auth.qml`   | HTTP Bearer token auth flow |
| `test_http_query_params.qml`  | HTTP query strings, PATCH, HEAD |
| `test_http_status_codes.qml`  | HTTP all verbs + status handling |
| `test_pharos_http.qml`        | Real-world: Pharos lighting via HTTP |
| `test_grandma_telnet.qml`     | Real-world: GrandMA via Telnet/TCP |
| `test_casparcg_amcp.qml`      | Real-world: CasparCG AMCP via TCP |
| `test_hyperdeck_control.qml`  | Real-world: Blackmagic HyperDeck |
| `test_pjlink_projector.qml`   | Real-world: PJLink projector TCP |
| `test_extron_sis.qml`         | Real-world: Extron SIS serial/TCP |
| `test_kramer_p3000.qml`       | Real-world: Kramer P3000 |
| `test_videohub_router.qml`    | Real-world: Blackmagic VideoHub |
| `test_watchout_control.qml`   | Real-world: Dataton Watchout TCP |
| `test_etc_eos_osc.qml`        | Real-world: ETC Eos lighting OSC |

---

## 7. MIDI Controller Use-Case Checklist

To build a MIDI controller mapper that controls ossia scenario parameters:

- [ ] Call `Protocols.inboundMIDIDevices()` at startup and pick the target device
- [ ] Open with `Protocols.inboundMIDI(...)` and store in a `property var`
- [ ] In `onMessage`, decode `msg.bytes[0] & 0xF0` for message type
- [ ] Map CC (0xB0), Note On (0x90), Note Off (0x80), Pitch Bend (0xE0) as needed
- [ ] Normalize values: CC `/ 127.0`, pitch bend `(raw - 8192) / 8192.0`
- [ ] Write to the device tree with `Device.write("/path", normalizedValue)`
- [ ] Declare all output nodes in `createTree()` — once, before connections open
- [ ] For bidirectional control (e.g., motorized faders), also open `Protocols.outboundMIDI()`
