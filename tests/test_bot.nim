## The scripted baselines must play whole episodes without ever proposing an
## illegal action — they are both the no-credentials fallback (offline
## certification) and fieldable policies, so this is the completion path. The
## `tally` jury must also land inside the truth-tracking band: below the floor
## the jury half of the benchmark is noise, above the ceiling it is trivial.

import std/[json, monotimes, sets, strutils, times, unicode, unittest]
import tribunal/[llm, sim]

proc fixture(seed: int, rounds = 4): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig, kinds: array[Seats, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in result.orderedSeats():
      let decision = scriptedAction(result, seat, kinds[seat])
      ## The baseline's move must be legal as-is: applyDecision raises on
      ## anything else and would fail this test.
      result.applyDecision(seat, decision, true)

proc uniform(kind: ScriptKind): array[Seats, ScriptKind] =
  for index in 0 ..< Seats:
    result[index] = kind

suite "scripted baselines":
  test "both baselines play every role legally, boundedly and fast":
    for seed in [1, 7, 42, 1234]:
      for kind in [skTally, skHedge]:
        let config = fixture(seed)
        let started = getMonoTime()
        let sim = playScripted(config, uniform(kind))
        let elapsed = (getMonoTime() - started).inMilliseconds
        check sim.done
        check sim.reason == "complete"
        check sim.roundsPlayed == config.rounds
        check sim.verdict in ["guilty", "not_guilty"]
        var seen = initHashSet[string]()
        var introducedBy = [0, 0]
        var arguments = 0
        var votes = 0
        for event in sim.events:
          case event.kind
          of evArgue:
            inc arguments
            check event.cards.len <= MaxIntroducePerTurn
            check event.text.len > 0
            check event.text.runeLen <= MaxArgumentLen
            check event.scripted
            for id in event.cards:
              check id notin seen
              seen.incl(id)
              introducedBy[event.role] += 1
          of evWhisper:
            ## The scripted jurors are silent.
            check event.text.len == 0
            check event.notes.len == 0
          of evVote:
            inc votes
            check event.vote in ["guilty", "not_guilty"]
          else:
            discard
        check arguments == config.rounds * 2
        check votes == Jurors
        for side in 0 .. 1:
          check introducedBy[side] <= sim.handOf(side).len
          check sim.shownBy(side) == introducedBy[side]
        check sim.record.len == seen.len
        check elapsed < 2000
        echo "seed ", seed, " ", kind, ": verdict ", sim.verdict, " truth ",
          sim.truthVerdict(), " record ", sim.record.len, " cards, ", elapsed,
          " ms"

  test "tally never introduces a card that hurts it; hedge holds back":
    for seed in [2, 3, 5]:
      let tally = playScripted(fixture(seed), uniform(skTally))
      for entry in tally.record:
        check entry.card.points ==
          (if entry.side == 0: "guilt" else: "innocence")
      ## Hedge shows at most one card a round until the closing round.
      let hedge = playScripted(fixture(seed), uniform(skHedge))
      for event in hedge.events:
        if event.kind == evArgue and event.round < hedge.config.rounds - 1:
          check event.cards.len <= 1

  test "an all-tally jury tracks the truth in the intended band":
    ## The deck's ambiguity band is tuned so that weighing the PUBLIC record
    ## — everything both advocates chose to show — is better than chance and
    ## far from certain. Outside 55%..85% the jury half of the benchmark has
    ## drifted and the deck needs retuning, not the test.
    var correct = 0
    let seeds = 400
    for seed in 0 ..< seeds:
      let sim = playScripted(fixture(seed), uniform(skTally))
      if sim.verdict == sim.truthVerdict():
        inc correct
    let rate = correct / seeds
    echo "all-tally truth-tracking rate over ", seeds, " seeds: ", rate
    check rate >= 0.55
    check rate <= 0.85

  test "decideAll falls back to scripted with no credentials":
    let config = fixture(3, rounds = 2)
    let client = newLlmClient(config)
    check client.disabled
    var sim = initSim(config)
    let seats = sim.pendingSeats()
    check seats.len == Seats
    let decisions = client.decideAll(sim, seats,
      @["be bold", "", "", "", ""],
      @[skNone, skNone, skHedge, skNone, skNone])
    check decisions.len == Seats
    ## Every decision comes from the SAME snapshot — the turn is simultaneous
    ## — so the expectations are all computed before anything is applied.
    var expected: seq[Decision]
    for seat in seats:
      expected.add(scriptedAction(sim, seat,
        (if seat == 2: skHedge else: skTally)))
    for index, seat in seats:
      check decisions[index].introduce == expected[index].introduce
      check decisions[index].argument == expected[index].argument
      check decisions[index].lean == expected[index].lean
      ## A scripted decision says so, whether the seat was configured
      ## scripted or fell back — the server stamps the event from this, so
      ## the replay never calls a fallback an LLM decision.
      check decisions[index].scripted
    check not parseAdvocateReply(%*{"argument": "my own words"}).scripted
    for index, seat in seats:
      sim.applyDecision(seat, decisions[index], true)
    check sim.round == 1

suite "reply parsing":
  test "documented spellings are accepted and every field is capped":
    var sim = initSim(fixture(4, rounds = 2))
    let prosecutor = sim.advocateSeat[0]
    let mine = sim.handOf(0)
    let advocate = parseAdvocateReply(parseJson(
      """{"introduce": ["e1", "E2", "E3"], "argument": "we begin\nhere",
          "notes": "keeping E9"}"""))
    ## At most two ids survive, and the newline is flattened.
    check advocate.introduce == @["e1", "E2"]
    check advocate.argument == "we begin here"
    check advocate.notes == "keeping E9"
    check parseAdvocateReply(parseJson(
      """{"argument": "no cards named"}""")).introduce.len == 0
    expect TribunalError:
      discard parseAdvocateReply(parseJson("""{"introduce": ["E1"]}"""))
    expect TribunalError:
      discard parseAdvocateReply(parseJson("""{"argument": "   "}"""))

    let juror = parseJurorReply(parseJson(
      """{"whisper": "8 to 5 for guilt", "lean": "Not Guilty"}"""))
    check juror.whisper == "8 to 5 for guilt"
    check juror.lean == "not_guilty"
    check parseJurorReply(parseJson("""{}""")).lean == "undecided"
    check parseJurorReply(parseJson(
      """{"lean": "sideways"}""")).lean == "undecided"

    for spelling in ["guilty", "GUILTY", " g ", "convict"]:
      check parseVoteReply(%*{"vote": spelling}).vote == "guilty"
    for spelling in ["not_guilty", "not guilty", "NotGuilty", "innocent",
        "acquit", "n"]:
      check normalizeVote(spelling) == "not_guilty"
    check normalizeVote("maybe") == ""
    expect TribunalError:
      discard parseVoteReply(parseJson("""{"reason": "no vote"}"""))
    expect TribunalError:
      discard parseVoteReply(parseJson("""{"vote": "maybe"}"""))

    ## Caps, on rune boundaries.
    var long = ""
    for index in 0 ..< 900:
      long.add("é")
    check cleanText(long, MaxNotesLen).runeLen == MaxNotesLen
    check cleanText(long, MaxArgumentLen).runeLen == MaxArgumentLen
    check cleanText(long, MaxWhisperLen).runeLen == MaxWhisperLen
    check cleanText(long, MaxReasonLen).validateUtf8() == -1

    ## An unknown card id is dropped by the rules, not rejected.
    sim.applyArgument(prosecutor, @["E99", mine[0].id], "one good id", "",
      false)
    check sim.record.len == 1
    check sim.record[0].card.id == mine[0].id

    check parseScriptKind("1") == skTally
    check parseScriptKind("tally") == skTally
    check parseScriptKind("hedge") == skHedge
    check parseScriptKind("") == skNone

  test "prompts carry the seat's own view and nothing hidden":
    var sim = initSim(fixture(7, rounds = 3))
    let prosecutor = sim.advocateSeat[0]
    let defender = sim.advocateSeat[1]
    let juror = sim.jurorSeat[0]
    let mine = sim.handOf(0)
    sim.applyArgument(prosecutor, @[mine[0].id], "look at " & mine[0].id, "",
      true)
    sim.applyArgument(defender, @[], "nothing to see", "", true)
    for index in 0 ..< Jurors:
      sim.applyWhisper(sim.jurorSeat[index], "juror " & $index & " counts",
        "undecided", "", true)

    let advocateText = sim.userPrompt(prosecutor, "operator says hi")
    check "YOUR HAND" in advocateText
    check "operator says hi" in advocateText
    check "DISCLOSURE" in advocateText
    check mine[0].text in advocateText
    ## No whisper ever reaches an advocate.
    for index in 0 ..< Jurors:
      check ("juror " & $index & " counts") notin advocateText

    let jurorText = sim.userPrompt(juror, "")
    check "WHAT THE JURY HAS BEEN SHOWN" in jurorText
    check "WHISPERS FROM THE OTHER JURORS LAST ROUND" in jurorText
    check "juror 1 counts" in jurorText
    check "juror 2 counts" in jurorText
    ## A juror never hears its own whisper back, and never sees a held card.
    check "juror 0 counts" notin jurorText
    for card in sim.handOf(1):
      if card.introducedRound < 0:
        check card.text notin jurorText
    ## The ballot turn asks for a vote.
    var ballot = sim
    while ballot.phase == phArgument:
      for seat in ballot.orderedSeats():
        ballot.applyDecision(seat, scriptedAction(ballot, seat, skTally), true)
    check ballot.phase == phBallot
    check "SEALED BALLOT" in ballot.userPrompt(ballot.jurorSeat[0], "")
