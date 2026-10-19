"""Play both certified trials through exports and numeric bridge decisions."""

import hashlib
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

directory = tempfile.mkdtemp(prefix="tribunal-training-")
print("Retained proof:", directory, flush=True)
for variant, rounds in (("standard", 4), ("long-trial", 5)):
    output = Path(directory) / variant
    subprocess.run([str(EXPORTER), str(output), "10", variant], cwd=ROOT, check=True)
    manifest = json.loads((output / "manifest.json").read_text())
    records = [json.loads(line) for line in (output / "trajectories.jsonl").read_text().splitlines()]
    decisions = [row for row in records if row["event_type"] == "decision"]
    episodes = [row for row in records if row["event_type"] == "episode"]
    per_game = 5 * rounds + 3
    assert len(manifest["runs"]) == len(episodes) == 10
    assert len(decisions) == 10 * per_game
    assert (output / "trajectories.jsonl").stat().st_mode & 0o777 == 0o600
    assert [e["seed_family"] for e in episodes] == [f"tribunal-{seed}" for seed in range(1, 11)]
    assert all(run["rounds"] == rounds and run["decisions"] == per_game for run in manifest["runs"])
    for row in decisions:
        system, user = (part["content"] for part in row["prompt"])
        assert "OUTPUT FORMAT" in system
        assert "CASE" in user or "case" in user
        for message in row["prompt"]:
            assert (
                row["observation"]["prompt_template"][message["role"] + "_sha256"]
                == hashlib.sha256(message["content"].encode()).hexdigest()
            )
        attempt = row["attempts"][0]
        assert attempt["origin"] == "teacher" and attempt["accepted"]
        assert row["selected_attempt_id"] == attempt["attempt_id"]
        assert row["executed_action"] == attempt["parsed_action"] == json.loads(attempt["response"])
    for episode in episodes:
        assert episode["status"] == "completed"
        assert len(episode["participant_outcomes"]) == 5
        rows = [row for row in decisions if row["episode_id"] == episode["episode_id"]]
        for seat in range(5):
            assert [row for row in rows if row["seat"] == str(seat)][-1]["terminal"]

    for teacher in (True, False):
        process = subprocess.Popen(
            [str(BRIDGE), str(MANIFEST), variant],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
            cwd="/tmp",
        )
        assert process.stdin is not None and process.stdout is not None
        rng = random.Random(13)

        def request(payload: dict) -> dict:
            process.stdin.write(json.dumps(payload) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        try:
            observation = request({"kind": "reset", "players": 5, "seed": f"tribunal-{variant}-{teacher}"})
            decisions = 0
            while observation["kind"] == "decision":
                assert observation["decision_id"] == decisions
                assert "OUTPUT FORMAT" in observation["semantic_view"]["system"]
                encoded = request({"kind": "encode"})
                assert len(encoded["values"]) == 42
                assert encoded["actions"] == [{"choice": 0}, {"choice": 1}]
                action = (
                    json.loads(request({"kind": "teacher"})["response"]) if teacher else rng.choice(encoded["actions"])
                )
                accepted = request({"kind": "step", "decision_id": decisions, "response": json.dumps(action)})
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
