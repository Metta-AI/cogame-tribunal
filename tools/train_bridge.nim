## JSONL numeric bridge over the native Tribunal simulator.

import std/[hashes, json, os]
import tribunal/[sim, llm]

var
  game: Sim
  seats: seq[int]
  cursor: int
  decisionId: int
  choices: array[Seats, int]
  manifestPath: string
  variant: string

proc currentDecision(): JsonNode =
  let seat = seats[cursor]
  let system = systemPrompt(game, seat)
  let user = userPrompt(game, seat, "")
  %*{"kind": "decision", "game": "tribunal",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": game.round,
    "semantic_view": {"system": system, "user": user},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 1}},
      "required": ["choice"]}, "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %(hash(command["seed"].getStr()) and 0x7FFFFFFF)
  var config = defaultGameConfig()
  config.update($variantConfig)
  config = config.sampleEpisode()
  game = initSim(config)
  seats = game.orderedSeats()
  cursor = 0
  decisionId = 0
  choices = [0, 0, 0, 0, 0]
  currentDecision()

proc encode(): JsonNode =
  let seat = seats[cursor]
  var values = newJArray()
  for name in ["standard", "long-trial"]:
    values.add(%(if variant == name: 1 else: 0))
  for player in 0 ..< Seats:
    values.add(%(if seat == player: 1 else: 0))
  for role in 0 .. 2:
    values.add(%(if game.roleOf[seat] == role: 1 else: 0))
  values.add(%(if game.phase == phArgument: 1 else: 0))
  values.add(%(if game.phase == phBallot: 1 else: 0))
  values.add(%(float(game.round) / float(game.config.rounds)))
  values.add(%(float(game.roundsPlayed) / float(game.config.rounds)))
  let tally = game.recordTally()
  values.add(%(float(tally.guilt) / 36.0))
  values.add(%(float(tally.innocence) / 36.0))
  values.add(%(float(tally.guiltCards) / float(DeckSize)))
  values.add(%(float(tally.innocenceCards) / float(DeckSize)))
  var hand: array[DeckSize, float]
  if game.roleOf[seat] < 2:
    for card in game.handOf(game.roleOf[seat]):
      hand[cardNumber(card.id) - 1] =
        float(card.strength) / 3.0 *
        (if card.points == "guilt": 1.0 else: -1.0)
  for value in hand: values.add(%value)
  var record: array[DeckSize, float]
  for entry in game.record:
    record[cardNumber(entry.card.id) - 1] =
      float(entry.card.strength) / 3.0 *
      (if entry.card.points == "guilt": 1.0 else: -1.0)
  for value in record: values.add(%value)
  doAssert values.len == 42
  %*{"decision_id": decisionId, "values": values,
    "actions": [{"choice": 0}, {"choice": 1}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let choice = action["choice"].getInt()
  doAssert choice in 0 .. 1
  choices[seats[cursor]] = choice
  inc decisionId
  inc cursor
  if cursor == seats.len:
    var decisions: array[Seats, Decision]
    for seat in seats:
      let kind = if choices[seat] == 0: skTally else: skHedge
      decisions[seat] = scriptedAction(game, seat, kind)
    for seat in seats:
      game.applyDecision(seat, decisions[seat], true)
    seats = game.orderedSeats()
    cursor = 0
  let observation = if game.done:
    var scores = newJObject()
    var utilities = newJObject()
    for player in 0 ..< Seats:
      let score = game.score(player)
      scores[$player] = %score
      utilities[$player] = %score
    %*{"kind": "terminal", "scores": scores,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": action, "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: tribunal-train-bridge MANIFEST VARIANT", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  doAssert variant in ["standard", "long-trial"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(%*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
