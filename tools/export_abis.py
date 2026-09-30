#!/usr/bin/env python3
"""Export already-built artifacts; deterministic and network independent."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAMES = (
    "LaunchToken", "PvPadToken", "BondingCurve", "PvPadFactory",
    "PvPadHook", "KingOfThePad", "WorkerSubsidy", "FeeEscrow",
)
for name in NAMES:
    artifact = ROOT / "out" / (name + ".sol") / (name + ".json")
    abi = json.loads(artifact.read_text())["abi"]
    target = ROOT / "docs" / "abi" / (name + ".json")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(abi, indent=2) + "\n")
    print(target.relative_to(ROOT))
