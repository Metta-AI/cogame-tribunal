"""Play both certified trials through exports and numeric bridge decisions."""

import json
import random
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
BRIDGE = Path(sys.argv[2]).resolve()
MANIFEST = ROOT / "coworld_manifest_template.json"

with tempfile.TemporaryDirectory() as directory:
    for variant, rounds in (("standard", 4), ("long-trial", 5)):
        output = Path(directory) / variant
        subprocess.run([str(EXPORTER), str(output), "10", variant], cwd=ROOT, check=True)
        manifest = json.loads((output / "manifest.json").read_text())
        train = [json.loads(line) for line in (output / "train.jsonl").read_text().splitlines()]
        validation = [json.loads(line) for line in (output / "validation.jsonl").read_text().splitlines()]
        per_game = 5 * rounds + 3
        assert len(manifest["runs"]) == 10
        assert all(run["rounds"] == rounds and run["decisions"] == per_game
                   for run in manifest["runs"])
        assert len(train) == manifest["train_examples"] == 8 * per_game
        assert len(validation) == manifest["validation_examples"] == 2 * per_game
        for row in train + validation:
            system, user = (part["content"] for part in row["prompt"])
            assert "OUTPUT FORMAT" in system
            assert "CASE" in user or "case" in user
            reply = json.loads(row["completion"][0]["content"])
            assert set(reply) in ({"introduce", "argument", "notes"},
                                  {"whisper", "lean", "notes"},
                                  {"vote", "reason", "notes"})

        for teacher in (True, False):
            process = subprocess.Popen(
                [str(BRIDGE), str(MANIFEST), variant], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, text=True, bufsize=1, cwd="/tmp",
            )
            assert process.stdin is not None and process.stdout is not None
            rng = random.Random(13)

            def request(payload: dict) -> dict:
                process.stdin.write(json.dumps(payload) + "\n")
                process.stdin.flush()
                return json.loads(process.stdout.readline())

            try:
                observation = request({"kind": "reset", "players": 5,
                                       "seed": f"tribunal-{variant}-{teacher}"})
                decisions = 0
                while observation["kind"] == "decision":
                    assert observation["decision_id"] == decisions
                    assert "OUTPUT FORMAT" in observation["semantic_view"]["system"]
                    encoded = request({"kind": "encode"})
                    assert len(encoded["values"]) == 42
                    assert encoded["actions"] == [{"choice": 0}, {"choice": 1}]
                    action = (json.loads(request({"kind": "teacher"})["response"])
                              if teacher else rng.choice(encoded["actions"]))
                    accepted = request({"kind": "step", "decision_id": decisions,
                                        "response": json.dumps(action)})
                    assert accepted["kind"] == "accepted"
                    observation = accepted["observation"]
                    decisions += 1
                assert decisions == per_game
                assert set(observation["scores"]) == {"0", "1", "2", "3", "4"}
                assert all(-1 <= value <= 1 for value in observation["utilities"].values())
                print(variant, "teacher" if teacher else "random", decisions)
            finally:
                process.stdin.close()
                process.stdout.close()
                assert process.wait(timeout=5) == 0
