# Tribunal training

The exporter plays ten complete native trials per certified variant. It
records each seat's exact hosted system and user prompts, plus replies
accepted by the production parser. Every decision in a round uses the
same pre-turn state. The native simulator applies them in role order,
including the sealed ballot. Commit the source before exporting.

```sh
nim c -d:release --path:src -o:/tmp/tribunal-posttrain tools/export_posttrain.nim
/tmp/tribunal-posttrain /tmp/tribunal-data 10 standard
```

The other certified variant is `long-trial`. Outputs are private
`trajectories.jsonl` and `manifest.json` files. They retain exact prompt hashes,
teacher origin, installed actions, terminal outcomes for all five seats, and
source revision. These are candidates requiring independent review before
training admission. The shared Coworld importer owns splitting: all replicas
of `tribunal-SEED`, including both trial lengths, belong to one split.

The optional final arguments select `PROMPT_VARIANT` and `PROMPT_SEED`.
Five training introductions (`canonical`, `plain`, `numbered`, `questions`,
`reordered`) retain each role's complete rules and action instructions.
`mixed` selects one using an explicit nonnegative prompt seed, independent
of scenario randomness. `heldout-briefing` and `heldout-reference` are
evaluation-only and cannot enter source exports. Canonical is the default.

The ordinary host accepts `promptVariant` and `promptSeed` in its configuration.
Both bridge modes accept them on reset, along with `split` (`train`,
`validation`, or `test`). Training rejects held-out wording. Selection is
stable across seats, rounds, and retries; roles and identities remain specific
to each seat. Operator guidance and private observations retain their original
rendering. Deterministic comparisons do not establish improved learning stability.

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
