## Complete native trials with exact hosted prompts and parsed replies.

import std/[json, os, osproc, strutils]
import tribunal/[sim, llm]

proc reply(game: Sim, seat: int, decision: Decision): JsonNode =
  case game.turnKind(seat)
  of tkArgue:
    %*{"introduce": decision.introduce, "argument": decision.argument,
      "notes": decision.notes}
  of tkWhisper:
    %*{"whisper": decision.whisper, "lean": decision.lean,
      "notes": decision.notes}
  of tkVote:
    %*{"vote": decision.vote, "reason": decision.reason,
      "notes": decision.notes}

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: tribunal-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = config.sampleEpisode()
    var game = initSim(config)
    var rows: seq[string]
    while not game.done:
      let seats = game.orderedSeats()
      var decisions: array[Seats, Decision]
      for seat in seats:
        let kind = if (seed + game.round + seat) mod 2 == 0:
          skTally else: skHedge
        let decision = scriptedAction(game, seat, kind)
        let completion = reply(game, seat, decision)
        let accepted = game.parseReply(seat, completion)
        doAssert accepted.introduce == decision.introduce
        doAssert accepted.argument == decision.argument
        doAssert accepted.vote == decision.vote
        decisions[seat] = accepted
        rows.add($(%*{
          "episode_id": "tribunal-" & variant & "-" & $seed,
          "seed": "tribunal-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(game, seat)},
            {"role": "user", "content": userPrompt(game, seat, "")}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "tribunal",
          "action_schema_revision": "tribunal-reply-v1"
        }))
      for seat in seats:
        game.applyDecision(seat, decisions[seat], true)
    let results = game.resultsJson()
    doAssert game.roundsPlayed == config.rounds
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "rounds": game.roundsPlayed,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "tribunal", "variant": variant,
    "source_revision": revision, "teacher": "tally-and-hedge",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
