## Sim unit tests: the seeded scenario, the resolution order, the sealing of
## the ballot, the scoring, the deadline settle, rune truncation and replay
## re-derivation. Every test drives the same pure module the server, the wasm
## viewer and the scripted bots drive.

import std/[json, sets, strutils, unicode, unittest]
import tribunal/[llm, sim]

proc fixtureConfig(rounds = 4, seed = 0): GameConfig =
  result = defaultGameConfig()
  result.rounds = rounds
  result.seed = seed
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc actAll(sim: var Sim, argument = "the record speaks", whisper = "counting",
    lean = "undecided") =
  ## One whole argument round, applied in role order.
  for seat in sim.orderedSeats():
    if sim.roleOf[seat] == 2:
      sim.applyWhisper(seat, whisper & " " & $seat, lean, "", true)
    else:
      sim.applyArgument(seat, @[], argument & " " & $seat, "", true)

proc playToBallot(config: GameConfig): Sim =
  result = initSim(config)
  while result.phase == phArgument:
    result.actAll()

proc castBallot(config: GameConfig, votes: array[Jurors, string]): Sim =
  result = playToBallot(config)
  for index in 0 ..< Jurors:
    result.applyVote(result.jurorSeat[index], votes[index], "because", "",
      true)

proc agreeingMargin(sim: Sim): int =
  ## A - D: the agreeing strength less the disagreeing strength.
  for card in sim.deck:
    let agrees = (card.points == "guilt") == sim.truthGuilty
    if agrees: result += card.strength
    else: result -= card.strength

proc textMatchesPolarity(sim: Sim, card: EvidenceCard): bool =
  let index = EvidenceKinds.find(card.kind)
  if index < 0:
    return false
  if card.points == "guilt":
    return card.text == GuiltTexts[index].replace("{who}", sim.accused)
  if card.text == InnocenceSelfTexts[index].replace("{who}", sim.accused):
    return true
  for name in sim.suspects:
    if name != sim.accused and
        card.text == InnocenceOtherTexts[index].replace("{who}", name):
      return true
  false

suite "setup":
  test "roles are a seeded permutation of one prosecutor, one defender and " &
      "three jurors":
    for seed in [0, 1, 7, 42, 1234]:
      let sim = initSim(fixtureConfig(seed = seed))
      var counts = [0, 0, 0]
      for seat in 0 ..< Seats:
        counts[sim.roleOf[seat]] += 1
      check counts == [1, 1, 3]
      check sim.roleOf[sim.advocateSeat[0]] == 0
      check sim.roleOf[sim.advocateSeat[1]] == 1
      var boxed = initHashSet[int]()
      for index in 0 ..< Jurors:
        let seat = sim.jurorSeat[index]
        check sim.roleOf[seat] == 2
        check sim.juryIndex[seat] == index
        boxed.incl(seat)
      check boxed.len == Jurors
      check sim.juryIndex[sim.advocateSeat[0]] == -1
      check sim.juryIndex[sim.advocateSeat[1]] == -1
      ## Jurors are numbered by ascending seat.
      for index in 1 ..< Jurors:
        check sim.jurorSeat[index] > sim.jurorSeat[index - 1]
    ## No slot is structurally stuck with a role.
    var prosecutors = initHashSet[int]()
    for seed in 0 ..< 20:
      prosecutors.incl(initSim(fixtureConfig(seed = seed)).advocateSeat[0])
    check prosecutors.len > 1

  test "the scenario is a well-formed, only-just-decisive case":
    var guiltyTruths = 0
    for seed in 0 ..< 500:
      let sim = initSim(fixtureConfig(seed = seed))
      check sim.deck.len == DeckSize
      for index in 0 ..< DeckSize:
        let card = sim.deck[index]
        check card.id == "E" & $(index + 1)
        check card.strength in 1 .. 3
        check card.points in ["guilt", "innocence"]
        check card.holder in {0, 1}
        check card.introducedRound == -1
        check sim.textMatchesPolarity(card)
      ## The whole deck points at the truth, but only just.
      let margin = sim.agreeingMargin()
      check margin >= DeckMarginMin
      check margin <= DeckMarginMax
      ## The accused is the culprit exactly when the truth says guilty.
      check (sim.accused == sim.culprit) == sim.truthGuilty
      check sim.culprit in sim.suspects
      check sim.accused in sim.suspects
      check sim.charge.startsWith(sim.accused)
      check sim.brief.startsWith(sim.charge)
      if sim.truthGuilty:
        inc guiltyTruths
    check guiltyTruths >= 125
    check guiltyTruths <= 375
    ## The viewer's alias rewriter must never be able to rewrite a suspect.
    var aliases = initHashSet[string]()
    for name in CogNames:
      aliases.incl(name)
    for name in SuspectNames:
      check name notin aliases

  test "the deal is uneven and blind to polarity":
    var prosecutionHurt = 0
    var defenceHurt = 0
    for seed in 0 ..< 200:
      let sim = initSim(fixtureConfig(seed = seed))
      let prosecution = sim.handOf(0)
      let defence = sim.handOf(1)
      check prosecution.len + defence.len == DeckSize
      check (prosecution.len == 7 and defence.len == 5) or
        (prosecution.len == 5 and defence.len == 7)
      var ids = initHashSet[string]()
      for card in prosecution:
        ids.incl(card.id)
      for card in defence:
        check card.id notin ids
        ids.incl(card.id)
      check ids.len == DeckSize
      for card in prosecution:
        if card.points == "innocence": inc prosecutionHurt
      for card in defence:
        if card.points == "guilt": inc defenceHurt
    check prosecutionHurt > 0
    check defenceHurt > 0

  test "seed determinism":
    let a = initSim(fixtureConfig(seed = 77))
    let b = initSim(fixtureConfig(seed = 77))
    let c = initSim(fixtureConfig(seed = 78))
    check a.roleOf == b.roleOf
    check a.suspects == b.suspects
    check a.culprit == b.culprit
    check a.truthGuilty == b.truthGuilty
    check a.charge == b.charge
    check a.names == b.names
    for index in 0 ..< DeckSize:
      check a.deck[index] == b.deck[index]
    check a.charge != c.charge or a.culprit != c.culprit or
      a.roleOf != c.roleOf

suite "argument rounds":
  test "introduction legality: unmatched, duplicate, foreign and extra ids " &
      "are dropped":
    var sim = initSim(fixtureConfig(seed = 5))
    let prosecutor = sim.advocateSeat[0]
    let defender = sim.advocateSeat[1]
    let mine = sim.handOf(0)
    let theirs = sim.handOf(1)
    sim.applyArgument(prosecutor,
      @[mine[0].id, mine[0].id, theirs[0].id, "E99", mine[1].id, mine[2].id],
      "we open", "", true)
    check sim.record.len == MaxIntroducePerTurn
    check sim.record[0].card.id == mine[0].id
    check sim.record[1].card.id == mine[1].id
    for entry in sim.record:
      check entry.side == 0
      check entry.seat == prosecutor
      check entry.round == 0
    ## Case-insensitive matching, and the record keeps prosecutor-then-
    ## defender order because decisions are applied in ROLE order.
    sim.applyArgument(defender, @[theirs[0].id.toLowerAscii()], "we answer",
      "", true)
    check sim.record.len == 3
    check sim.record[2].card.id == theirs[0].id
    check sim.record[2].side == 1
    check sim.shownBy(0) == 2
    check sim.heldBy(0) == sim.handOf(0).len - 2
    check sim.shownBy(1) == 1
    check sim.heldBy(1) == sim.handOf(1).len - 1
    ## A card that was never introduced is nowhere in the record.
    var recorded = initHashSet[string]()
    for entry in sim.record:
      recorded.incl(entry.card.id)
    for card in sim.handOf(0):
      if card.introducedRound < 0:
        check card.id notin recorded
    ## An advocate speaks once a round; a juror may not argue.
    expect TribunalError:
      sim.applyArgument(prosecutor, @[], "again", "", true)
    expect TribunalError:
      sim.applyArgument(sim.jurorSeat[0], @[], "me too", "", true)
    expect TribunalError:
      sim.applyArgument(prosecutor, @[], "   ", "", true)

  test "whispers reach the other two jurors next round and nobody else":
    var sim = initSim(fixtureConfig(rounds = 3, seed = 6))
    for index in 0 ..< Jurors:
      check sim.playerStateJson(sim.jurorSeat[index])["heard"].len == 0
    sim.actAll()
    check sim.round == 1
    for index in 0 ..< Jurors:
      let seat = sim.jurorSeat[index]
      let heard = sim.playerStateJson(seat)["heard"]
      check heard.len == Jurors - 1
      var senders = initHashSet[int]()
      for entry in heard:
        senders.incl(entry["juror"].getInt())
      check index notin senders
    for side in 0 .. 1:
      let advocate = sim.playerStateJson(sim.advocateSeat[side])
      check advocate["heard"].len == 0
      check not advocate.hasKey("whispers")
    ## `heard` is last round's; the current round's whispers are invisible.
    sim.applyWhisper(sim.jurorSeat[0], "brand new", "guilty", "", true)
    let other = sim.playerStateJson(sim.jurorSeat[1])
    for entry in other["heard"]:
      check entry["text"].getStr() != "brand new"

suite "sealing":
  test "no frame before the verdict frame carries a vote, the truth or the " &
      "culprit":
    let config = fixtureConfig(rounds = 2, seed = 9)
    var sim = playToBallot(config)
    for frame in replayMatch(config, sim.events):
      let state = frame.tableStateJson()
      check state["votes"].len == Jurors
      for vote in state["votes"]:
        check vote.kind == JNull
      check state["sealed"].getBool()
      check state["truth"].getStr() == ""
      check state["culprit"].getStr() == ""
      check state["correctJurors"].getInt() == -1
      for seat in state["seats"]:
        check seat["vote"].kind == JNull
    ## Prompts carry no vote, no reveal and no label for the truth. (The
    ## culprit's NAME is one of the four public suspects and is printed in
    ## every prompt by design; what must never leak is which of them it is.)
    sim.applyVote(sim.jurorSeat[0], "guilty", "record says so", "", true)
    for seat in 0 ..< Seats:
      let text = sim.userPrompt(seat, "operator guidance") &
        sim.systemPrompt(seat)
      check sim.revealLine() notin text
      check "culprit" notin text.toLowerAscii()
      check "record says so" notin text
      ## No seat is ever told that another seat has voted, or how.
      check "voted" notin text.toLowerAscii()
    ## On the verdict frame everything fills in.
    sim.applyVote(sim.jurorSeat[1], "guilty", "same", "", true)
    sim.applyVote(sim.jurorSeat[2], "not_guilty", "no", "", true)
    let final = sim.tableStateJson()
    check not final["sealed"].getBool()
    check final["verdict"].getStr() == "guilty"
    check final["truth"].getStr() == sim.truthVerdict()
    check final["culprit"].getStr() == sim.culprit
    check final["correctJurors"].getInt() in 0 .. Jurors
    for vote in final["votes"]:
      check vote.getStr() in ["guilty", "not_guilty"]

suite "verdict and scoring":
  test "hand-built ballots give the documented verdicts and scores":
    let config = fixtureConfig(rounds = 2, seed = 12)
    let cases = [
      (["guilty", "guilty", "guilty"], "guilty", 1.0),
      (["guilty", "guilty", "not_guilty"], "guilty", 1.0 / 3.0),
      (["guilty", "not_guilty", "not_guilty"], "not_guilty", -1.0 / 3.0),
      (["not_guilty", "not_guilty", "not_guilty"], "not_guilty", -1.0)
    ]
    for (votes, verdict, prosecutorScore) in cases:
      let sim = castBallot(config, votes)
      check sim.done
      check sim.reason == "complete"
      check sim.verdict == verdict
      let prosecution = sim.score(sim.advocateSeat[0])
      let defence = sim.score(sim.advocateSeat[1])
      check abs(prosecution - prosecutorScore) < 1e-9
      check abs(prosecution + defence) < 1e-9
      var correct = 0
      for index in 0 ..< Jurors:
        let seat = sim.jurorSeat[index]
        let score = sim.score(seat)
        check abs(abs(score) - 1.0) < 1e-9
        check (score > 0) == (votes[index] == sim.truthVerdict())
        if score > 0: inc correct
      check sim.correctJurors() == correct
      let results = sim.resultsJson()
      check results["verdict"].getStr() == verdict
      check results["correctJurors"].getInt() == correct

  test "the deadline settles the episode instead of discarding it":
    var sim = initSim(fixtureConfig(rounds = 4, seed = 13))
    sim.actAll()
    sim.applyArgument(sim.advocateSeat[0], @[], "mid round", "", true)
    check sim.phase == phArgument
    sim.forceBallot()
    check sim.done
    check sim.reason == "deadline"
    check sim.verdict in ["guilty", "not_guilty"]
    for index in 0 ..< Jurors:
      check sim.votes[index] in ["guilty", "not_guilty"]
    for seat in 0 ..< Seats:
      let score = sim.score(seat)
      check score >= -1.0
      check score <= 1.0
    let events = sim.events.len
    ## endEarly on a settled sim is a no-op.
    sim.endEarly()
    check sim.events.len == events
    check sim.events[^1].kind == evEnd
    check sim.events[^1].text == "deadline"
    check sim.events[^2].kind == evVerdict
    let results = sim.resultsJson()
    check results["reason"].getStr() == "deadline"
    check results["rounds"].getInt() == 1

suite "text safety":
  test "a multi-byte argument is cut on rune boundaries and stays valid " &
      "UTF-8":
    var sim = initSim(fixtureConfig(rounds = 2, seed = 14))
    var long = ""
    for index in 0 ..< 400:
      long.add("日")
    var notes = ""
    for index in 0 ..< 800:
      notes.add("é")
    sim.applyArgument(sim.advocateSeat[0], @[], long, notes, true)
    let argued = sim.argumentOf(sim.advocateSeat[0])
    check argued.runeLen == MaxArgumentLen
    check argued.validateUtf8() == -1
    ## Notes are capped by the rules too, not only by the LLM parse path.
    check sim.notes[sim.advocateSeat[0]].runeLen == MaxNotesLen
    check sim.events[^1].notes.runeLen == MaxNotesLen
    var whisper = ""
    for index in 0 ..< 500:
      whisper.add("ß")
    sim.applyWhisper(sim.jurorSeat[0], whisper, "guilty", "", true)
    check sim.whisperOf(sim.jurorSeat[0]).runeLen == MaxWhisperLen
    ## Everything that lands in the replay JSON round-trips as strict UTF-8.
    for event in sim.events:
      check event.text.validateUtf8() == -1
      check event.notes.validateUtf8() == -1
      let back = eventFromJson(eventToJson(event))
      check back.text == event.text
    check ($sim.tableStateJson()).validateUtf8() == -1
    check ($sim.resultsJson()).validateUtf8() == -1

suite "replay":
  test "a recorded episode re-derives frame by frame":
    let config = fixtureConfig(rounds = 3, seed = 15)
    var live = initSim(config)
    var roundIndex = 0
    while live.phase == phArgument:
      for seat in live.orderedSeats():
        if live.roleOf[seat] == 2:
          live.applyWhisper(seat, "seat " & $seat & " counts", "guilty",
            "notes " & $roundIndex, true)
        else:
          let hand = live.handOf(live.roleOf[seat])
          var ids: seq[string]
          for card in hand:
            if card.introducedRound < 0 and ids.len < 1:
              ids.add(card.id)
          live.applyArgument(seat, ids, "round " & $roundIndex & " for " & $seat,
            "notes " & $roundIndex, true)
      inc roundIndex
    for index in 0 ..< Jurors:
      live.applyVote(live.jurorSeat[index],
        (if index == 0: "guilty" else: "not_guilty"), "reason " & $index, "",
        true)
    check live.done
    let frames = replayMatch(config, live.events)
    check frames.len == live.events.len + 1
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check frames[^1].reason == "complete"

  test "a deadline episode re-derives, and a tampered round event is " &
      "rejected":
    let config = fixtureConfig(rounds = 4, seed = 16)
    var short = initSim(config)
    short.actAll()
    short.applyArgument(short.advocateSeat[0], @[], "cut short", "", true)
    short.forceBallot()
    let frames = replayMatch(config, short.events)
    check frames.len == short.events.len + 1
    check frames[^1].done
    check frames[^1].reason == "deadline"
    check $frames[^1].tableStateJson() == $short.tableStateJson()

    var events = short.events
    var tamperedAt = -1
    for index, event in events:
      if event.kind == evRound and event.round == 1:
        tamperedAt = index
    check tamperedAt > 0
    events[tamperedAt].cards.add("E12")
    expect TribunalError:
      discard replayMatch(config, events)

  test "a deadline at the ballot re-derives as a deadline, not as complete":
    ## The likeliest deadline shape: the play budget runs out during the
    ## closing round, so the phase is already `phBallot` when the deadline is
    ## detected at the top of the ballot turn. Nothing in the vote events
    ## distinguishes it from a normal ballot — the `end` event's reason is
    ## what the replay has to carry.
    let config = fixtureConfig(rounds = 2, seed = 21)
    var live = playToBallot(config)
    check live.phase == phBallot
    live.applyVote(live.jurorSeat[0], "guilty", "sure of it", "", true)
    live.forceBallot()
    check live.reason == "deadline"
    let frames = replayMatch(config, live.events)
    check frames.len == live.events.len + 1
    check frames[^1].done
    check frames[^1].reason == "deadline"
    check frames[^1].events[^1].kind == evEnd
    check frames[^1].events[^1].text == "deadline"
    check $frames[^1].tableStateJson() == $live.tableStateJson()
    check frames[^1].resultsJson()["reason"].getStr() == "deadline"

  test "every event kind round-trips through JSON":
    let config = fixtureConfig(rounds = 2, seed = 17)
    var sim = playToBallot(config)
    for index in 0 ..< Jurors:
      sim.applyVote(sim.jurorSeat[index], "guilty", "clear", "note", true)
    var seenKinds = initHashSet[EventKind]()
    for event in sim.events:
      seenKinds.incl(event.kind)
      check eventFromJson(eventToJson(event)) == event
    for kind in EventKind:
      check kind in seenKinds

suite "results":
  test "results carry five of everything and a legal reason":
    let config = fixtureConfig(rounds = 2, seed = 18)
    let sim = castBallot(config, ["guilty", "not_guilty", "guilty"])
    let results = sim.resultsJson()
    for key in ["names", "scores", "roles", "votes"]:
      check results[key].len == Seats
    check results["reason"].getStr() in ["complete", "deadline"]
    check results["correctJurors"].getInt() in 0 .. Jurors
    check results["cardsIntroduced"].getInt() +
      results["cardsHeld"].getInt() == DeckSize
    check results["rounds"].getInt() == 2
    check results["maxRounds"].getInt() == 2
    for seat in 0 ..< Seats:
      check results["names"][seat].getStr() == config.players[seat].name
      check results["roles"][seat].getStr() == sim.roleName(seat)
      let vote = results["votes"][seat].getStr()
      if sim.roleOf[seat] == 2:
        check vote in ["guilty", "not_guilty"]
      else:
        check vote == ""
      let score = results["scores"][seat].getFloat()
      check score >= -1.0
      check score <= 1.0
