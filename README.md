# Tribunal

An **adjudication coworld** for the Softmax Coworld platform, on the
[cogame-bullwhip](https://github.com/Metta-AI/cogame-bullwhip) technology
stack (parley lineage). Five cogs sit around one criminal case: a
**Prosecutor** and a **Defender**, scored only on winning the verdict, and a
**jury of three**, scored only on matching a truth nobody in the room can see.

The seed draws four suspects, a hidden **culprit**, a coin-flip **truth** about
whether the accused did it, and twelve evidence cards. Each card points at
guilt or innocence with a strength of 1–3, and the deck is redrawn until the
whole of it points at the truth by a margin of only **1 to 4** — decisive, but
only just. The twelve cards are then dealt **7/5 or 5/7** and **blind to
polarity**, so each advocate routinely holds cards that argue against it and is
never required to introduce them.

Each of the four argument rounds, both advocates may introduce up to **2** of
their own cards and make **one argument** (320 characters). Only introduced
cards ever reach the jury — but the jury is told how many cards each side
**holds** and how many it has **shown**, so suppression is inferable and never
visible. Jurors whisper 200 characters to the *other two* jurors (read next
round), record a lean, and after the closing round cast **one sealed vote**
each. Two guilty votes convict. Then, and only then, the truth is revealed and
the real culprit is named.

Decisions inside a round are **simultaneous**: every pending seat's prompt goes
out in one parallel batch — five in an argument round, three in the ballot — and
nothing said in round *t* is visible to any other seat before round *t+1*.

**The game is LLM-driven and a policy is just a prompt.** Every turn the server
sends each seat's policy prompt plus its role-specific view (the case, its own
hand *or* the public record, the transcript, the disclosure counts, the
whispers it is allowed to hear, its private notes) to Claude, and Claude answers
with the move. Player containers exist only to deliver their prompt. Two
built-in **scripted baselines** — `tally` (weighs the record's strengths; as an
advocate introduces its two strongest own-side cards and never one that hurts
it) and `hedge` (counts cards instead of weighing them; shows one card a round
and dumps the rest in the closing round) — play any seat that registers as
scripted, and every seat when no LLM credentials are available, so episodes
(and offline certification) always complete.

Seats play under **anonymous cog aliases** (Sprocket, Gizmo, …): policy display
names never reach a prompt, so nobody can meta-game "that seat is the
champion". The spectator and replay viewers map the aliases back to policy
names; results are reported under policy names. Suspect names are a third
namespace, asserted disjoint from the aliases, so the rewriter can never touch
the case.

## Scoring

- **Advocates**: `score = (2 × myVotes − 3) / 3` — **+1.0** for a 3–0 sweep,
  **+1/3** for 2–1, **−1/3** for 1–2, **−1.0** for 0–3. The two advocates
  always sum to exactly zero. Truth does not score an advocate; winning does.
- **Jurors**: **+1.0** if the juror's own vote matches the hidden truth, else
  **−1.0**. Individually scored — a juror who is right while outvoted still
  scores +1.
- Nobody knows the truth during the episode, the advocates included. A knowing
  prosecutor would leak the answer through its argument and the jury would learn
  to read confidence instead of evidence.

The episode ends `complete` (the ballot resolved) or `deadline` (the play clock
reached 60% of the episode timeout first — the bench calls the ballot, the
scripted tally vote stands in for any juror who has not voted, and the verdict,
the reveal and the scores are produced normally).

## Layout

- `src/tribunal.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/tribunal/sim.nim` — pure rules: the seeded scenario, the resolution
  order, introduction legality, whisper routing, the sealed ballot, scoring and
  replay derivation; shared by server, tests and the wasm viewer
- `src/tribunal/llm.nim` — Claude client (one parallel batch per turn) + the two
  scripted baselines
- `src/tribunal/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/tribunal_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — shared canvas renderer + global/player/replay pages (the parley
  broadcast chrome around the courtroom stage)
- `replay-viewer/` — static wasm replay viewer (`?replay=<url>`)
- `tools/build_replay_viewer.sh` — Coworld replay-viewer build hook
- `tools/make_manifest.py` — regenerates `coworld_manifest_template.json`
- `tools/make_violet_cog.py` — generates the fifth seat sprite
- `data/` — cog sprites and art, borrowed from
  [coworld-ctf](https://github.com/Metta-AI/coworld-ctf) (MIT), plus a violet
  recolour for the fifth seat
- `docs/plans/` — the design note this game was built from

## Local loop

```bash
export PATH="$HOME/.nimby/nim/bin:$PATH"
nimby --global sync nimby.lock                 # fetch pinned packages
# Generate nim.cfg from your nimby package tree (not committed - the paths are
# machine-specific):
rm -f nim.cfg
for pkg in ~/.nimby/pkgs/*; do
  if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg;
  else echo "--path:\"$pkg\"" >> nim.cfg; fi
done
echo '--path:"src"' >> nim.cfg

nim r --path:src tests/test_sim.nim            # rules tests
nim r -d:release --path:src tests/test_bot.nim # scripted-baseline tests
nim c -d:release -o:bin/tribunal src/tribunal.nim
nim c -d:release -o:bin/tribunal-player src/tribunal_player.nim
nim c --hints:off -d:emscripten replay-viewer/tribunal_replay.nim  # wasm viewer

# One whole episode in raw docker, the certification fixture's seat mix, no
# credentials (the game must complete on its scripted baselines):
docker build --platform=linux/amd64 -t coworld-tribunal:ci .
./tools/ci/docker_smoke.sh coworld-tribunal:ci
```

Coworld packaging (from a metta checkout):

```bash
uv run coworld build --project <this dir> --version 0.1.x
uv run coworld certify <this dir>/dist/coworld_manifest.json
uv run coworld upload-coworld <this dir>/dist/coworld_manifest.json
uv run coworld secret put tribunal anthropic_api_key <keyfile>   # hosted Claude
```

In CI, `.github/workflows/coworld-release.yml` does all four in the right order
(build → certify → upload policies → upload coworld → put secret).

## Fielding a policy

```bash
uv run coworld upload-policy <tribunal image> --name my-tribunal \
  --run /bin/tribunal-player \
  --secret-env PLAYER_PROMPT="Your courtroom strategy here."
```

Your role is dealt by the seed, so a good prompt covers both: how to argue and
what to hold back as an advocate, and how to weigh the record — and correct for
what you are *not* being shown — as a juror.

Or field a scripted baseline: same image, `--env PLAYER_SCRIPTED=tally` or
`--env PLAYER_SCRIPTED=hedge`.

## Watching

The replay is a **static wasm bundle**, never a pod: `tools/build_replay_viewer.sh`
compiles the same Nim sim to WebAssembly and bundles it with the renderer, so the
viewer re-derives every frame from the recorded events in the browser and
nothing is fetched but the `.replay` file. The stage is a courtroom — the bench
with the case and the four suspects, the two podiums with their disclosure
readouts and speech bubbles, twelve card slots where held cards are face-down
and an introduced card flips face-up, the jury box with a tipping scale per
juror while the ballot is sealed, and the scales of evidence along the bottom.
On the verdict the envelopes open, the bench stamps the verdict, and a spotlight
sweeps to the real culprit.
