#!/usr/bin/env python3
"""Inject devices-mapper.qml into a .score file's Mapper device."""
import json, sys, pathlib

QML  = pathlib.Path(__file__).with_name("devices-mapper.qml")
SCORE = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(
    "~/Dropbox/Prog/scores/jam-mapper.score").expanduser()

data = json.loads(SCORE.read_text())
qml  = QML.read_text()

for pi, plugin in enumerate(data.get("Plugins", [])):
    for ci, child in enumerate(plugin.get("Children", [])):
        if child.get("Device", {}).get("Text", "").startswith("// devices-mapper.qml"):
            data["Plugins"][pi]["Children"][ci]["Device"]["Text"] = qml
            SCORE.write_text(json.dumps(data, indent=2))
            print(f"Injected {len(qml)} chars into {SCORE}")
            raise SystemExit(0)

print("ERROR: mapper device not found in score file", file=sys.stderr)
raise SystemExit(1)
