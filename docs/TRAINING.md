# Tribunal prompt diversity and training

The v2 bank varies each role's evidence, communication, score, and privacy
explanations. Five training presentations include canonical, plain, numbered,
questions, and reordered. Two held-out presentations are evaluation-only.
Canonical rules, operator guidance, strategic hints, and JSON syntax remain fixed.
An independent nonnegative prompt seed chooses mixed wording once per episode.

The exporter plays complete five-seat native trials with tally and hedge
teachers. Every seat observes the same pre-turn state; decisions resolve only
after the full batch. Outputs retain the original train.jsonl, validation.jsonl,
and manifest.json contracts, adding selection, message hashes, and scenario
families. Every fifth seed is validation. Mixed wording cycles independently
within each split; both trial lengths share the same scenario family.

```sh
nim c -d:release --path:src -o:/tmp/tribunal-posttrain tools/export_posttrain.nim
/tmp/tribunal-posttrain /tmp/tribunal-data 10 standard mixed 0
```

Use standard or long-trial. Held-out wording cannot enter training exports.
The native host accepts promptVariant and promptSeed. Both bridge modes accept
the same settings and a train, validation, or test split. Training rejects
held-out resets. Selection stays stable across seats, rounds, and retries;
roles and identities remain seat-specific. Private observations are unchanged.

Complete-game comparisons establish mechanical invariants, not stronger play
or less learning collapse. Learning studies must match policies, game seeds,
seats, opponents, and inference settings and reserve held-out presentations.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes hosted prompts and 42 numeric values:
public record tallies, the acting seat's role and private hand, and the
introduced cards. It never reads hidden truth, the other advocate's
hand, or sealed votes. Two choices select the published tally or hedge
policy. Terminal utilities are the game's own bounded [-1, 1] scores.
Post-training above retains arbitrary legal arguments, whispers, votes,
and notes.

Append `text` to the bridge command to submit those role-specific actions
directly. The production parser normalizes them, and the simulator validates
them before buffering. The round advances only after all pending seats submit.
Malformed actions terminate this local bridge; the ordinary native host retains
its existing retry and fallback behavior.

```sh
nim c -d:release --path:src -o:/tmp/tribunal-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/tribunal-posttrain /tmp/tribunal-train-bridge
python3 tools/test_prompt_games.py /tmp/tribunal-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute
bridge and manifest paths to `recipes.external.coworld.train` for native
PufferLib, or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=5` and choose `standard` or `long-trial`.

Both variants completed 512 Metta RL timesteps with checkpoints and held-out
evaluation. Native PufferLib trained 4,096 CUDA timesteps per variant in
Slurm job 9082, then reloaded checkpoints for held-out seeds 101 and 102.
Standard scored -0.143 and 0.714; long-trial scored -0.200 and 0.667.
These bounded runs verify execution, not stronger league play.
