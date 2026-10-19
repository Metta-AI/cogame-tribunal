## Complete private native trials; admission and splitting belong to the importer.

import std/[json, os, osproc, strutils]
import tribunal/[sim, llm, prompts, evidence]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 3 .. 5:
    quit("usage: tribunal-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT] [PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  var promptConfig = newJObject()
  if args.len >= 4: promptConfig["promptVariant"] = %args[3]
  if args.len == 5: promptConfig["promptSeed"] = %parseInt(args[4])
  let selection = promptSelection(promptConfig)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting private candidates"
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = config.sampleEpisode()
    var game = initSim(config)
    let family = "tribunal-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    var rows = newJArray()
    var latest: array[Seats, int]
    while not game.done:
      let seats = game.orderedSeats()
      var decisions: array[Seats, Decision]
      for seat in seats:
        let kind = if (seed + game.round + seat) mod 2 == 0:
          skTally else: skHedge
        let decision = scriptedAction(game, seat, kind)
        let completion = game.decisionJson(seat, decision)
        let accepted = game.parseReply(seat, completion)
        var probe = game
        probe.applyDecision(seat, accepted, true)
        let executed = game.decisionJson(seat, accepted)
        doAssert executed == completion
        decisions[seat] = accepted
        let system = systemPrompt(game, seat, selection)
        let user = userPrompt(game, seat, "")
        let observation = game.playerStateJson(seat)
        observation["prompt_template"] = promptMetadata(selection, system, user)
        let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
        let attemptId = $rows.len & "-teacher"
        latest[seat] = rows.len
        rows.add(%*{
          "schema_version": "1", "event_type": "decision", "episode_id": episode,
          "decision_id": $rows.len, "decision_index": rows.len,
          "game": "tribunal", "game_version": "source-" & revision,
          "source_revision": revision, "seat": $seat, "visibility": "private",
          "observation": observation, "prompt": messages,
          "attempts": [{"attempt_id": attemptId, "policy": "scripted-tally-and-hedge",
            "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
            "response": $completion, "parsed_action": executed, "accepted": true,
            "request": newJNull(), "platform_call_id": newJNull(),
            "behavior_logprobs": newJNull(), "rejection_reason": newJNull()}],
          "selected_attempt_id": attemptId, "executed_action": executed,
          "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
      for seat in seats:
        game.applyDecision(seat, decisions[seat], true)
    let results = game.resultsJson()
    doAssert game.roundsPlayed == config.rounds
    var outcomes = newJObject()
    for seat in 0 ..< Seats:
      rows[latest[seat]]["terminal"] = %true
      outcomes[$seat] = %*{"score": game.score(seat)}
    for row in rows: stream.writeLine($row)
    stream.writeLine($(%*{"schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "tribunal", "game_version": "source-" & revision,
      "source_revision": revision, "status": "completed", "outcome": results,
      "participant_outcomes": outcomes}))
    runs.add(%*{"seed": seed, "rounds": game.roundsPlayed,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]})
  stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "tribunal", "variant": variant,
    "source_revision": revision, "teacher": "scripted-tally-and-hedge",
    "prompt_configuration": selectionMetadata(selection),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs
  }) & "\n")
  echo "complete private games=", episodes
