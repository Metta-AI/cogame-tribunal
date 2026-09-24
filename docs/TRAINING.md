# Tribunal training

The exporter plays ten complete native trials per certified variant. It
records each seat's exact hosted system and user prompts, plus replies
accepted by the production parser. Every decision in a round uses the
same pre-turn state. The native simulator applies them in role order,
including the sealed ballot. Train and validation sets split full trials
by seed.

```sh
nim c -d:release --path:src -o:/tmp/tribunal-posttrain tools/export_posttrain.nim
/tmp/tribunal-posttrain /tmp/tribunal-data 10 standard
```

The other certified variant is `long-trial`. The output has
`train.jsonl`, `validation.jsonl`, and a manifest with source revision,
seeds, rounds, scores, and row counts. Ten trials yielded 184/46
standard and 224/56 long-trial train/validation decisions.

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/tribunal-data --output /tmp/tribunal-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes hosted prompts and 42 numeric values:
public record tallies, the acting seat's role and private hand, and the
introduced cards. It never reads hidden truth, the other advocate's
hand, or sealed votes. Two choices select the published tally or hedge
policy. Terminal utilities are the game's own bounded [-1, 1] scores.
Post-training above retains arbitrary legal arguments, whispers, votes,
and notes.

```sh
nim c -d:release --path:src -o:/tmp/tribunal-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/tribunal-posttrain /tmp/tribunal-train-bridge
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
