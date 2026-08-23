## Pure game rules for Tribunal. No IO, no networking, no LLM — the server,
## the tests and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: the seeded seat→role permutation, the hidden
## truth and culprit, the twelve-card deck and its uneven deal, the public
## record of introduced cards, the argument transcript, the jurors' whispers
## and their SEALED votes, each seat's private notes, and the append-only
## event log. Everything random is drawn from the seed at `initSim` — roles,
## truth, case, deck, deal, aliases, in that order — so a replay re-derives
## the whole scenario from the seed alone.

import std/[json, random, strutils, unicode], types

export types

const
  Seats* = 5
  Jurors* = 3
  DeckSize* = 12
  ## At most two cards may be introduced by one advocate in one round.
  MaxIntroducePerTurn* = 2
  ## Chance (percent) that a drawn card agrees with the hidden truth.
  TruthTiltPercent* = 60
  ## The whole deck points at the truth, but only just.
  DeckMarginMin* = 1
  DeckMarginMax* = 4
  DeckDrawAttempts* = 200
  MinRounds* = 2
  MaxRounds* = 5
  ## Worst case for one turn: a batch plus its retry, both at the LLM timeout.
  TurnBudgetSeconds* = 90
  ## Total spectator-pacing sleep an episode may spend, in milliseconds.
  PacingBudgetMs* = 20_000
  ## Share of the platform's episode timeout spent playing.
  PlayBudgetFraction* = 0.6
  MaxArgumentLen* = 320
  MaxWhisperLen* = 200
  MaxReasonLen* = 200
  ## The private notebook a seat may carry between rounds.
  MaxNotesLen* = 600
  RoleNames* = ["Prosecutor", "Defender", "Juror"]
  SideNames* = ["prosecution", "defence"]
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  ## Suspects are a third namespace, DISJOINT from CogNames (a test asserts
  ## it) so the viewer's alias → policy-name rewriter can never rewrite a
  ## suspect out of the case.
  SuspectNames* = [
    "Marlow Vex", "Ilse Prentiss", "Cato Brann", "Odile Ferrant",
    "Hugh Mallory", "Sable Wren", "Dorian Kest", "Vera Alms",
    "Tobias Rook", "Nell Carrow", "August Pike", "Zia Halloran"
  ]
  Items* = [
    "the Brass Astrolabe", "the Verdigris Key", "the Ivory Metronome",
    "the Cobalt Ledger", "the Gilded Sextant", "the Onyx Cylinder",
    "the Copper Nightingale", "the Alabaster Mask",
    "the Sable Chronometer", "the Ember Locket"
  ]
  Crimes* = [
    "stolen from", "smashed in", "swapped inside", "burned in",
    "spirited out of", "prised open in"
  ]
  Scenes* = [
    "the Clockwork Museum", "the Halberd Street vault", "the Foundry annexe",
    "the Verger's Library", "the Tin Quarter exchange",
    "the Astronomers' Guild", "the Old Cistern gallery",
    "the Marchmont auction house"
  ]
  Hours* = [
    "just before midnight", "at the third bell", "in the small hours",
    "at the dinner gong", "shortly after dusk", "at the changing of the watch"
  ]
  EvidenceKinds* = [
    "fingerprint", "ledger entry", "witness sighting", "tool mark",
    "timestamp", "alibi", "receipt", "fibre", "key card", "letter"
  ]
  ## Card sentences are keyed on polarity and kind so the text can never
  ## contradict the card's `points`. Guilt cards name the accused; innocence
  ## cards either clear the accused or put an alternate suspect in the frame.
  GuiltTexts* = [
    "A clean fingerprint lifted from the empty mounting matches {who}.",
    "The night ledger has {who} signing into the east wing eleven minutes " &
      "before the case was opened.",
    "A porter puts {who} in the corridor outside the case at the hour in " &
      "question.",
    "The tool marks on the case match a jemmy found in {who}'s workshop.",
    "The door log timestamps {who}'s key at the exact minute the alarm loop " &
      "went quiet.",
    "{who}'s account of that evening does not survive: the tram they name " &
      "never ran that night.",
    "A receipt in {who}'s hand covers a glass cutter bought two days before.",
    "Fibres caught on the broken frame match the coat {who} wore that week.",
    "{who}'s key card opened the service door forty minutes after closing.",
    "A letter in {who}'s hand offers the item to a buyer before it was ever " &
      "missed."
  ]
  InnocenceSelfTexts* = [
    "The only fingerprint on the mounting is not {who}'s; it is on no roll " &
      "at all.",
    "The night ledger shows {who} signing out a full hour before the case " &
      "was touched.",
    "A night warden saw {who} on the far side of the building when the " &
      "alarm sounded.",
    "The tool marks were made by a jemmy of a pattern {who} has never owned.",
    "The door log has {who}'s key nowhere near that room in the whole window.",
    "{who}'s alibi holds: two people place them elsewhere for the entire hour.",
    "A receipt puts {who} paying for supper across the city at the time.",
    "The fibres on the frame are wool; {who} wore oilcloth that night.",
    "{who}'s key card was never presented at any door after closing.",
    "A letter in {who}'s hand asks for the item's guard to be doubled that " &
      "very week."
  ]
  InnocenceOtherTexts* = [
    "A second fingerprint on the mounting matches {who}, who had no " &
      "business there.",
    "The night ledger has {who} signing in twice and out once.",
    "A porter saw {who} leaving by the service stair with a covered parcel.",
    "The tool marks match a jemmy borrowed by {who} and never returned.",
    "The door log has {who}'s key in the room minutes before the alarm loop " &
      "went quiet.",
    "{who} claimed to be at home that evening; the household says otherwise.",
    "A receipt shows {who} buying a glass cutter that same week.",
    "Fibres on the broken frame match a coat of {who}'s.",
    "{who}'s key card opened the service door long after closing.",
    "A letter in {who}'s hand names a buyer for exactly this item."
  ]
  BriefOpeners* = [
    "{a}, {b} and {c} were all in the building that night, and all three " &
      "had reason to be.",
    "{a}, {b} and {c} signed the night book within the same hour.",
    "{a}, {b} and {c} were the only other names on the roll that night."
  ]
  BriefClosers* = [
    "The loss was found at dawn, and every statement taken since has been " &
      "vague about the same twenty minutes.",
    "Nobody heard anything; the watch was walking the far corridor.",
    "The case was locked when the hall was locked and open when it was " &
      "unlocked."
  ]

type
  Phase* = enum
    phArgument = "argument"
    phBallot   = "ballot"
    phVerdict  = "verdict"
    phDone     = "done"

  Sim* = object
    config*: GameConfig
    names*: seq[string]            ## anonymous cog aliases per seat
    roleOf*: array[Seats, int]     ## seat -> 0 Prosecutor | 1 Defender | 2 Juror
    advocateSeat*: array[2, int]
    jurorSeat*: array[Jurors, int]
    juryIndex*: array[Seats, int]  ## juror seats -> 0..2; -1 otherwise
    suspects*: array[4, string]
    culprit*: string               ## HIDDEN until the verdict
    accused*: string
    truthGuilty*: bool             ## HIDDEN until the verdict
    caseTitle*, charge*, brief*: string
    deck*: array[DeckSize, EvidenceCard]
    record*: seq[RecordEntry]      ## introduced cards, in introduction order
    arguments*: seq[tuple[round, seat, side: int, text: string]]
    whispers*: seq[tuple[round, seat: int, text, lean: string]]
    heard*: array[Jurors, string]  ## last round's whispers, by juror index
    leans*: array[Jurors, string]
    votes*: array[Jurors, string]  ## "" until cast; SEALED until the verdict
    voteReasons*: array[Jurors, string]
    notes*: seq[string]            ## latest private notes per seat
    acted*: array[Seats, bool]     ## this turn
    round*: int
    roundsPlayed*: int
    phase*: Phase
    verdict*: string
    done*: bool
    reason*: string                ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Text helpers -----------------------------------------------------------

proc tidy*(text: string, limit: int): string =
  ## Strip, collapse newlines to spaces, and cut on a RUNE boundary: a byte
  ## slice through a multi-byte character would leave invalid UTF-8 in the
  ## replay and break its JSON.
  result = text.replace("\r", " ").replace("\n", " ").strip()
  if result.runeLen > limit:
    result = result.runeSubStr(0, limit)

proc fill(pattern: string, values: openArray[(string, string)]): string =
  result = pattern
  for (key, value) in values:
    result = result.replace(key, value)

proc cardNumber*(id: string): int =
  ## "E7" -> 7; anything unparsable sorts last.
  try:
    parseInt(id.strip(chars = {'E', 'e'}, trailing = false))
  except ValueError:
    high(int)

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the courtroom: every seat plays under
  ## an anonymous cog name, drawn deterministically from the seed so replays
  ## and the live table agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the argument rounds into the episode's play budget. Idempotent: a
  ## config that already carries the cap (a replay being re-read) is
  ## untouched.
  result = config
  if result.sampled:
    return
  let maxTurns = int(
    (PlayBudgetFraction * config.episodeTimeoutSeconds.float -
      config.playerConnectTimeoutSeconds) / TurnBudgetSeconds.float)
  var cap = min(MaxRounds, maxTurns - 1)
  if cap < MinRounds:
    cap = MinRounds
  result.rounds = max(MinRounds, min(config.rounds, cap))
  result.turnDelayMs =
    min(config.turnDelayMs, PacingBudgetMs div max(result.rounds + 1, 1))
  result.sampled = true

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, round: -1, seat: -1, role: -1)

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc recordIds*(sim: Sim): seq[string] =
  for entry in sim.record:
    result.add(entry.card.id)

proc composeCard(rng: var Rand, index: int, agrees, truthGuilty: bool,
    accused: string, others: seq[string]): EvidenceCard =
  let kindIndex = rng.rand(EvidenceKinds.high)
  let strength = 1 + rng.rand(2)
  let points = if agrees == truthGuilty: "guilt" else: "innocence"
  var text: string
  if points == "guilt":
    text = GuiltTexts[kindIndex].fill({"{who}": accused})
  elif rng.rand(1) == 0:
    text = InnocenceSelfTexts[kindIndex].fill({"{who}": accused})
  else:
    text = InnocenceOtherTexts[kindIndex].fill(
      {"{who}": others[rng.rand(others.high)]})
  EvidenceCard(id: "E" & $(index + 1), kind: EvidenceKinds[kindIndex],
    strength: strength, points: points, text: text, holder: -1,
    introducedRound: -1)

proc fallbackDeck(truthGuilty: bool, accused: string,
    others: seq[string]): array[DeckSize, EvidenceCard] =
  ## Reached only if 200 draws never land inside the ambiguity band (measured
  ## over 5,000 seeds: mean 5.2 attempts, max 42). Seven agreeing cards and
  ## five disagreeing ones, margin 3.
  const agreeStrengths = [2, 2, 2, 1, 1, 1, 1]
  const denyStrengths = [2, 2, 1, 1, 1]
  for index in 0 ..< DeckSize:
    let agrees = index < agreeStrengths.len
    let strength =
      if agrees: agreeStrengths[index] else: denyStrengths[index - agreeStrengths.len]
    let points = if agrees == truthGuilty: "guilt" else: "innocence"
    let kindIndex = index mod EvidenceKinds.len
    let text =
      if points == "guilt": GuiltTexts[kindIndex].fill({"{who}": accused})
      else: InnocenceOtherTexts[kindIndex].fill(
        {"{who}": others[index mod others.len]})
    result[index] = EvidenceCard(id: "E" & $(index + 1),
      kind: EvidenceKinds[kindIndex], strength: strength, points: points,
      text: text, holder: -1, introducedRound: -1)

proc openRound(sim: var Sim) =
  ## The round becomes live: nobody has acted, last round's whispers move
  ## into `heard`, and the record's ids at open are logged as a
  ## re-derivation cross-check.
  sim.phase = phArgument
  for seat in 0 ..< Seats:
    sim.acted[seat] = false
  for index in 0 ..< Jurors:
    sim.heard[index] = ""
    sim.leans[index] = ""
  for whisper in sim.whispers:
    if whisper.round == sim.round - 1:
      sim.heard[sim.juryIndex[whisper.seat]] = whisper.text
  var event = blankEvent(evRound)
  event.round = sim.round
  event.cards = sim.recordIds()
  if sim.round == sim.config.rounds - 1:
    event.text = "closing"
  sim.addEvent(event)

proc openBallot(sim: var Sim) =
  ## The advocates are done; the three jurors cast one sealed vote each.
  sim.phase = phBallot
  for seat in 0 ..< Seats:
    sim.acted[seat] = sim.roleOf[seat] != 2

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(TribunalError,
      "tribunal needs exactly " & $Seats & " players")
  if config.rounds < MinRounds:
    raise newException(TribunalError,
      "rounds must be at least " & $MinRounds)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  ## One stream for everything the seed decides, in a fixed order: roles,
  ## truth, case, deck, deal.
  var rng = initRand(int64(config.seed) * 7919 + 17)

  ## 1. Roles: exactly one prosecutor, one defender, three jurors.
  var roles = @[0, 1, 2, 2, 2]
  rng.shuffle(roles)
  var jurorsSeen = 0
  for seat in 0 ..< Seats:
    result.roleOf[seat] = roles[seat]
    result.juryIndex[seat] = -1
    case roles[seat]
    of 0: result.advocateSeat[0] = seat
    of 1: result.advocateSeat[1] = seat
    else:
      result.jurorSeat[jurorsSeen] = seat
      result.juryIndex[seat] = jurorsSeen
      inc jurorsSeen

  ## 2. Suspects, culprit, truth. The accused is public; the culprit and the
  ## truth are not, until the verdict.
  var pool = @SuspectNames
  rng.shuffle(pool)
  for index in 0 ..< 4:
    result.suspects[index] = pool[index]
  result.culprit = result.suspects[rng.rand(3)]
  result.truthGuilty = rng.rand(1) == 1
  if result.truthGuilty:
    result.accused = result.culprit
  else:
    var innocents: seq[string]
    for name in result.suspects:
      if name != result.culprit:
        innocents.add(name)
    result.accused = innocents[rng.rand(innocents.high)]
  var others: seq[string]
  for name in result.suspects:
    if name != result.accused:
      others.add(name)

  ## 3. The case text.
  let item = Items[rng.rand(Items.high)]
  let crime = Crimes[rng.rand(Crimes.high)]
  let scene = Scenes[rng.rand(Scenes.high)]
  let hour = Hours[rng.rand(Hours.high)]
  result.caseTitle =
    if item.startsWith("the "): "The " & item[4 .. ^1] else: "The " & item
  result.charge = result.accused & " is charged: " & item & " was " & crime &
    " " & scene & ", " & hour & "."
  result.brief = result.charge & " " &
    BriefOpeners[rng.rand(BriefOpeners.high)].fill(
      {"{a}": others[0], "{b}": others[1], "{c}": others[2]}) & " " &
    BriefClosers[rng.rand(BriefClosers.high)]

  ## 4. The deck: redrawn whole until the evidence points at the truth by a
  ## margin of 1..4. Without the band a naive strength tally is right ~92% of
  ## the time and the jury half of the benchmark is trivial; with it the same
  ## tally lands near 66%.
  var drawn = false
  for attempt in 0 ..< DeckDrawAttempts:
    var agreeing = 0
    var disagreeing = 0
    for index in 0 ..< DeckSize:
      let agrees = rng.rand(99) < TruthTiltPercent
      result.deck[index] = composeCard(rng, index, agrees, result.truthGuilty,
        result.accused, others)
      if agrees:
        agreeing += result.deck[index].strength
      else:
        disagreeing += result.deck[index].strength
    let margin = agreeing - disagreeing
    if margin >= DeckMarginMin and margin <= DeckMarginMax:
      drawn = true
      break
  if not drawn:
    result.deck = fallbackDeck(result.truthGuilty, result.accused, others)

  ## 5. The deal, blind to polarity: 7/5 or 5/7.
  var order = newSeq[int](DeckSize)
  for index in 0 ..< DeckSize:
    order[index] = index
  rng.shuffle(order)
  let prosecutionSize = if rng.rand(1) == 1: 7 else: 5
  for position, index in order:
    result.deck[index].holder = if position < prosecutionSize: 0 else: 1

  result.notes = newSeq[string](Seats)
  result.round = 0
  result.phase = phArgument
  result.addEvent(blankEvent(evStart))
  result.openRound()

# ---- Queries ----------------------------------------------------------------

proc roleName*(sim: Sim, seat: int): string =
  RoleNames[sim.roleOf[seat]]

proc truthVerdict*(sim: Sim): string =
  if sim.truthGuilty: "guilty" else: "not_guilty"

proc revealed*(sim: Sim): bool =
  ## True once the verdict has been read out: only then do the votes, the
  ## truth and the culprit exist anywhere outside the sim.
  sim.verdict.len > 0

proc pendingSeats*(sim: Sim): seq[int] =
  ## Seats still owing an action this turn, in SEAT order (prompt building).
  if sim.done:
    return
  case sim.phase
  of phArgument:
    for seat in 0 ..< Seats:
      if not sim.acted[seat]:
        result.add(seat)
  of phBallot:
    for seat in 0 ..< Seats:
      if sim.roleOf[seat] == 2 and sim.votes[sim.juryIndex[seat]].len == 0:
        result.add(seat)
  else:
    discard

proc orderedSeats*(sim: Sim): seq[int] =
  ## The same seats in ROLE order — prosecutor, defender, jurors 0..2 — which
  ## is the order decisions are applied in, so the record's card order depends
  ## on the seed rather than on slot numbering.
  let pending = sim.pendingSeats()
  for side in 0 .. 1:
    if sim.advocateSeat[side] in pending:
      result.add(sim.advocateSeat[side])
  for index in 0 ..< Jurors:
    if sim.jurorSeat[index] in pending:
      result.add(sim.jurorSeat[index])

proc handOf*(sim: Sim, side: int): seq[EvidenceCard] =
  ## Every card dealt to that side, introduced or not, in id order.
  for index in 0 ..< DeckSize:
    if sim.deck[index].holder == side:
      result.add(sim.deck[index])

proc heldBy*(sim: Sim, side: int): int =
  for index in 0 ..< DeckSize:
    if sim.deck[index].holder == side and sim.deck[index].introducedRound < 0:
      inc result

proc shownBy*(sim: Sim, side: int): int =
  for index in 0 ..< DeckSize:
    if sim.deck[index].holder == side and sim.deck[index].introducedRound >= 0:
      inc result

proc recordTally*(sim: Sim): tuple[guilt, innocence, guiltCards,
    innocenceCards: int] =
  ## What the jury can actually see, weighed and counted.
  for entry in sim.record:
    if entry.card.points == "guilt":
      result.guilt += entry.card.strength
      inc result.guiltCards
    else:
      result.innocence += entry.card.strength
      inc result.innocenceCards

proc tallyVote*(sim: Sim): string =
  ## The truth-tracking baseline's verdict from the public record alone:
  ## weigh the strengths, and acquit on a tie (presumption of innocence).
  let tally = sim.recordTally()
  if tally.guilt > tally.innocence: "guilty" else: "not_guilty"

proc tallyReason*(sim: Sim): string =
  let tally = sim.recordTally()
  let lean =
    if tally.guilt > tally.innocence: " for guilt"
    elif tally.innocence > tally.guilt: " for innocence"
    else: " level; presumption of innocence"
  "record " & $tally.guilt & " to " & $tally.innocence & lean

proc argumentOf*(sim: Sim, seat: int): string =
  ## The seat's argument in the CURRENT round ("" before it speaks).
  for entry in sim.arguments:
    if entry.seat == seat and entry.round == sim.round:
      return entry.text
  ""

proc whisperOf*(sim: Sim, seat: int): string =
  for entry in sim.whispers:
    if entry.seat == seat and entry.round == sim.round:
      return entry.text
  ""

proc score*(sim: Sim, seat: int): float =
  ## Zero until the verdict is read. Advocates score on the verdict alone,
  ## jurors on the truth alone; both ranges are [-1, +1] by construction.
  if not sim.revealed():
    return 0.0
  let role = sim.roleOf[seat]
  if role == 2:
    return if sim.votes[sim.juryIndex[seat]] == sim.truthVerdict(): 1.0
      else: -1.0
  let want = if role == 0: "guilty" else: "not_guilty"
  var mine = 0
  for index in 0 ..< Jurors:
    if sim.votes[index] == want:
      inc mine
  (2.0 * mine.float - 3.0) / 3.0

proc correctJurors*(sim: Sim): int =
  if not sim.revealed():
    return -1
  for index in 0 ..< Jurors:
    if sim.votes[index] == sim.truthVerdict():
      inc result

proc revealLine*(sim: Sim): string =
  sim.caseTitle & " was taken by " & sim.culprit & "."

proc seatScripted*(sim: Sim, seat: int): bool =
  ## Whether the seat's most recent action came from a scripted baseline.
  for index in countdown(sim.events.high, 0):
    let event = sim.events[index]
    if event.seat == seat and
        event.kind in {evArgue, evWhisper, evVote}:
      return event.scripted
  false

# ---- Play -------------------------------------------------------------------

proc settle(sim: var Sim) =
  ## Tally the sealed ballot, reveal the truth, score, and close the episode.
  if sim.done:
    return
  var guilty = 0
  for index in 0 ..< Jurors:
    if sim.votes[index] == "guilty":
      inc guilty
  sim.verdict = if guilty >= 2: "guilty" else: "not_guilty"
  sim.phase = phVerdict
  var verdictEvent = blankEvent(evVerdict)
  verdictEvent.round = sim.config.rounds
  verdictEvent.verdict = sim.verdict
  verdictEvent.truth = sim.truthVerdict()
  verdictEvent.text = sim.revealLine()
  for index in 0 ..< Jurors:
    verdictEvent.votes.add(sim.votes[index])
  sim.addEvent(verdictEvent)
  if sim.reason.len == 0:
    sim.reason = "complete"
  sim.done = true
  sim.phase = phDone
  var endEvent = blankEvent(evEnd)
  endEvent.round = sim.roundsPlayed
  endEvent.text = sim.reason
  sim.addEvent(endEvent)

proc resolveRound(sim: var Sim) =
  ## All five seats have acted: the round closes.
  inc sim.roundsPlayed
  inc sim.round
  if sim.round < sim.config.rounds:
    sim.openRound()
  else:
    sim.openBallot()

proc applyArgument*(sim: var Sim, seat: int, cardIds: seq[string],
    argument, notes: string, scripted: bool) =
  ## An advocate introduces up to MaxIntroducePerTurn of its own un-introduced
  ## cards and makes one argument. Unmatched, duplicate and already-introduced
  ## ids are DROPPED (a reply that names a card it does not hold still
  ## argues); an empty argument is illegal.
  if sim.done:
    raise newException(TribunalError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(TribunalError, "bad seat: " & $seat)
  if sim.phase != phArgument:
    raise newException(TribunalError, "the argument rounds are over")
  let side = sim.roleOf[seat]
  if side notin {0, 1}:
    raise newException(TribunalError, sim.names[seat] & " is not an advocate")
  if sim.acted[seat]:
    raise newException(TribunalError,
      sim.names[seat] & " has already spoken this round")
  let text = tidy(argument, MaxArgumentLen)
  if text.len == 0:
    raise newException(TribunalError, "an argument may not be empty")

  var introduced: seq[string]
  for wanted in cardIds:
    if introduced.len >= MaxIntroducePerTurn:
      break
    let want = wanted.strip().toLowerAscii()
    for index in 0 ..< DeckSize:
      if sim.deck[index].holder == side and
          sim.deck[index].introducedRound < 0 and
          sim.deck[index].id.toLowerAscii() == want:
        sim.deck[index].introducedRound = sim.round
        sim.record.add(RecordEntry(card: sim.deck[index], round: sim.round,
          side: side, seat: seat))
        introduced.add(sim.deck[index].id)
        break

  sim.arguments.add((round: sim.round, seat: seat, side: side, text: text))
  if notes.len > 0:
    sim.notes[seat] = tidy(notes, MaxNotesLen)
  var event = blankEvent(evArgue)
  event.round = sim.round
  event.seat = seat
  event.role = side
  event.cards = introduced
  event.text = text
  event.notes = sim.notes[seat]
  event.scripted = scripted
  sim.addEvent(event)
  sim.acted[seat] = true
  if sim.pendingSeats().len == 0:
    sim.resolveRound()

proc normalizeLean*(text: string): string =
  case text.strip().toLowerAscii().replace(" ", "_")
  of "guilty", "g", "guilt", "convict": "guilty"
  of "not_guilty", "notguilty", "innocent", "acquit", "n", "innocence":
    "not_guilty"
  else: "undecided"

proc applyWhisper*(sim: var Sim, seat: int, whisper, lean, notes: string,
    scripted: bool) =
  ## A juror whispers to the OTHER TWO jurors (they read it next round) and
  ## records a lean. Neither ever reaches an advocate.
  if sim.done:
    raise newException(TribunalError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(TribunalError, "bad seat: " & $seat)
  if sim.phase != phArgument:
    raise newException(TribunalError, "the argument rounds are over")
  if sim.roleOf[seat] != 2:
    raise newException(TribunalError, sim.names[seat] & " is not a juror")
  if sim.acted[seat]:
    raise newException(TribunalError,
      sim.names[seat] & " has already whispered this round")
  let text = tidy(whisper, MaxWhisperLen)
  let leaning = normalizeLean(lean)
  sim.leans[sim.juryIndex[seat]] = leaning
  sim.whispers.add((round: sim.round, seat: seat, text: text, lean: leaning))
  if notes.len > 0:
    sim.notes[seat] = tidy(notes, MaxNotesLen)
  var event = blankEvent(evWhisper)
  event.round = sim.round
  event.seat = seat
  event.role = 2
  event.text = text
  event.lean = leaning
  event.notes = sim.notes[seat]
  event.scripted = scripted
  sim.addEvent(event)
  sim.acted[seat] = true
  if sim.pendingSeats().len == 0:
    sim.resolveRound()

proc normalizeVote*(text: string): string =
  ## "" when the reply carries nothing that can be read as a vote.
  case text.strip().toLowerAscii().replace(" ", "_")
  of "guilty", "g", "guilt", "convict": "guilty"
  of "not_guilty", "notguilty", "innocent", "innocence", "acquit", "n":
    "not_guilty"
  else: ""

proc applyVote*(sim: var Sim, seat: int, vote, reason, notes: string,
    scripted: bool) =
  ## A juror casts its SEALED vote. Nothing about it reaches any other seat —
  ## or any frame — until the third vote settles the episode.
  if sim.done:
    raise newException(TribunalError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(TribunalError, "bad seat: " & $seat)
  if sim.phase != phBallot:
    raise newException(TribunalError, "the ballot is not open")
  if sim.roleOf[seat] != 2:
    raise newException(TribunalError, sim.names[seat] & " is not a juror")
  let index = sim.juryIndex[seat]
  if sim.votes[index].len > 0:
    raise newException(TribunalError, sim.names[seat] & " has already voted")
  let chosen = normalizeVote(vote)
  if chosen.len == 0:
    raise newException(TribunalError, "not a vote: " & vote)
  sim.votes[index] = chosen
  sim.voteReasons[index] = tidy(reason, MaxReasonLen)
  if notes.len > 0:
    sim.notes[seat] = tidy(notes, MaxNotesLen)
  var event = blankEvent(evVote)
  event.round = sim.config.rounds
  event.seat = seat
  event.role = 2
  event.vote = chosen
  event.text = sim.voteReasons[index]
  event.notes = sim.notes[seat]
  event.scripted = scripted
  sim.addEvent(event)
  if sim.pendingSeats().len == 0:
    sim.settle()

proc beginDeadlineBallot*(sim: var Sim) =
  ## The play deadline cut the argument short: the bench calls the ballot.
  ## Separate from `forceBallot` because a replay re-derives the same jump
  ## from the recorded vote events.
  if sim.done or sim.phase != phArgument:
    return
  sim.reason = "deadline"
  sim.openBallot()

proc forceBallot*(sim: var Sim) =
  ## The deadline settles the episode HERE: jurors who already voted keep
  ## their votes, every remaining juror is given the scripted tally vote from
  ## the public record, and the verdict, reveal and scores are produced
  ## normally with reason "deadline". A short honest trial always beats a
  ## long one that never lands.
  if sim.done:
    return
  sim.reason = "deadline"
  if sim.phase == phArgument:
    sim.openBallot()
  let vote = sim.tallyVote()
  let reason = sim.tallyReason()
  for index in 0 ..< Jurors:
    if sim.votes[index].len == 0:
      sim.applyVote(sim.jurorSeat[index], vote, reason, "", true)
  if not sim.done:
    sim.settle()

proc endEarly*(sim: var Sim) =
  ## Stop now. A no-op on an already-settled sim.
  sim.forceBallot()

# ---- Results ----------------------------------------------------------------

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var roles = newJArray()
  var votes = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, not by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    roles.add(%sim.roleName(seat))
    votes.add(%(
      if sim.roleOf[seat] == 2 and sim.revealed():
        sim.votes[sim.juryIndex[seat]]
      else: ""))
  %*{
    "names": names,
    "scores": scores,
    "roles": roles,
    "votes": votes,
    "verdict": sim.verdict,
    "truth": (if sim.revealed(): sim.truthVerdict() else: ""),
    "correctJurors": max(sim.correctJurors(), 0),
    "rounds": sim.roundsPlayed,
    "maxRounds": sim.config.rounds,
    "cardsIntroduced": sim.record.len,
    "cardsHeld": DeckSize - sim.record.len,
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Viewer state -----------------------------------------------------------

proc cardJson*(card: EvidenceCard): JsonNode =
  %*{
    "id": card.id,
    "kind": card.kind,
    "strength": card.strength,
    "points": card.points,
    "text": card.text,
    "holder": card.holder,
    "introducedRound": card.introducedRound
  }

proc caseJson*(sim: Sim): JsonNode =
  var suspects = newJArray()
  for name in sim.suspects:
    suspects.add(%name)
  %*{
    "title": sim.caseTitle,
    "accused": sim.accused,
    "charge": sim.charge,
    "brief": sim.brief,
    "suspects": suspects
  }

proc recordJson*(sim: Sim): JsonNode =
  result = newJArray()
  for entry in sim.record:
    result.add(%*{
      "id": entry.card.id,
      "side": entry.side,
      "seat": entry.seat,
      "round": entry.round,
      "kind": entry.card.kind,
      "strength": entry.card.strength,
      "points": entry.card.points,
      "text": entry.card.text
    })

proc transcriptJson*(sim: Sim): JsonNode =
  result = newJArray()
  for entry in sim.arguments:
    result.add(%*{
      "round": entry.round,
      "side": entry.side,
      "seat": entry.seat,
      "name": sim.names[entry.seat],
      "text": entry.text
    })

proc disclosureJson*(sim: Sim): JsonNode =
  %*{
    "prosecutionHolds": sim.handOf(0).len,
    "prosecutionShown": sim.shownBy(0),
    "defenceHolds": sim.handOf(1).len,
    "defenceShown": sim.shownBy(1)
  }

proc tableStateJson*(sim: Sim): JsonNode =
  ## One frame; the viewer draws exactly this. Before the verdict frame the
  ## votes are `[null, null, null]`, `sealed` is true and truth / culprit are
  ## empty — a test asserts it for EVERY earlier frame.
  let pending = sim.pendingSeats()
  let reveal = sim.revealed()
  var seats = newJArray()
  for seat in 0 ..< Seats:
    let role = sim.roleOf[seat]
    let jury = sim.juryIndex[seat]
    seats.add(%*{
      "name": sim.names[seat],
      "role": RoleNames[role],
      "roleId": role,
      "juryIndex": jury,
      "score": sim.score(seat),
      "handCount": (if role == 2: 0 else: sim.handOf(role).len),
      "held": (if role == 2: 0 else: sim.heldBy(role)),
      "introduced": (if role == 2: 0 else: sim.shownBy(role)),
      "argument": (if role == 2: "" else: sim.argumentOf(seat)),
      "whisper": (if role == 2: sim.whisperOf(seat) else: ""),
      "lean": (if role == 2: sim.leans[jury] else: ""),
      "vote": (if role == 2 and reveal: %sim.votes[jury] else: newJNull()),
      "voteReason": (if role == 2 and reveal: sim.voteReasons[jury] else: ""),
      "notes": sim.notes[seat],
      "pending": seat in pending,
      "scripted": sim.seatScripted(seat)
    })
  var jurorSeats = newJArray()
  for index in 0 ..< Jurors:
    jurorSeats.add(%sim.jurorSeat[index])
  var whispers = newJArray()
  for entry in sim.whispers:
    whispers.add(%*{
      "round": entry.round,
      "juror": sim.juryIndex[entry.seat],
      "seat": entry.seat,
      "name": sim.names[entry.seat],
      "text": entry.text,
      "lean": entry.lean
    })
  var votes = newJArray()
  for index in 0 ..< Jurors:
    votes.add(if reveal: %sim.votes[index] else: newJNull())
  let tally = sim.recordTally()
  %*{
    "case": sim.caseJson(),
    "seats": seats,
    "roleSeat": {
      "prosecutor": sim.advocateSeat[0],
      "defender": sim.advocateSeat[1],
      "jurors": jurorSeats
    },
    "record": sim.recordJson(),
    "transcript": sim.transcriptJson(),
    "whispers": whispers,
    "tally": {
      "guilt": tally.guilt,
      "innocence": tally.innocence,
      "guiltCards": tally.guiltCards,
      "innocenceCards": tally.innocenceCards
    },
    "round": sim.round,
    "rounds": sim.config.rounds,
    "roundsPlayed": sim.roundsPlayed,
    "phase": $sim.phase,
    "votes": votes,
    "sealed": not reveal,
    "verdict": sim.verdict,
    "truth": (if reveal: sim.truthVerdict() else: ""),
    "culprit": (if reveal: sim.culprit else: ""),
    "correctJurors": sim.correctJurors(),
    "gameDone": sim.done,
    "reason": (if sim.done: sim.reason else: "")
  }

proc playerStateJson*(sim: Sim, seat: int): JsonNode =
  ## The seat's own private view: its role, the case, the public record, the
  ## transcript, its own hand (advocates) or the other jurors' whispers from
  ## LAST round (jurors), the disclosure counts and its own notes. Never the
  ## seed, the truth, the culprit, another seat's hand, a whisper from this
  ## round, or any vote. Decisions are server-side, so the redaction loses
  ## nothing.
  let role = sim.roleOf[seat]
  result = %*{
    "slot": seat,
    "name": sim.names[seat],
    "role": RoleNames[role],
    "roleId": role,
    "juryIndex": sim.juryIndex[seat],
    "case": sim.caseJson(),
    "record": sim.recordJson(),
    "transcript": sim.transcriptJson(),
    "disclosure": sim.disclosureJson(),
    "round": sim.round,
    "rounds": sim.config.rounds,
    "phase": $sim.phase,
    "done": sim.done,
    "reason": (if sim.done: sim.reason else: "")
  }
  var hand = newJArray()
  if role != 2:
    for card in sim.handOf(role):
      hand.add(cardJson(card))
  result["hand"] = hand
  var heard = newJArray()
  if role == 2:
    for index in 0 ..< Jurors:
      if index != sim.juryIndex[seat] and sim.heard[index].len > 0:
        heard.add(%*{
          "juror": index,
          "name": sim.names[sim.jurorSeat[index]],
          "text": sim.heard[index]
        })
  result["heard"] = heard

# ---- Replay -----------------------------------------------------------------

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[Sim] =
  ## Re-derives the state timeline from a recorded event log by replaying the
  ## decisions through the rules (roles, truth, deck and deal come from the
  ## seed). frames[i] = state after events[0..<i]; the replayed sim's own
  ## event log mirrors the prefix so the feed lines up.
  var sim = initSim(config)
  ## initSim already logged the start and the first round event; the recorded
  ## log opens with those same two.
  sim.events = @[]
  ## The ending reason is a wall-clock signal (the play deadline), not
  ## something the rules re-derive; the log carries it in the `end` event's
  ## text. Seed it before replaying, otherwise a deadline that trips at or
  ## after the ballot opens re-derives as "complete": `beginDeadlineBallot`
  ## only fires while the phase is still `phArgument`, and `settle` defaults
  ## an empty reason. `reason` is rendered only once the sim is done
  ## (`tableStateJson`, `playerStateJson`), so no earlier frame changes.
  for event in events:
    if event.kind == evEnd and event.text.len > 0:
      sim.reason = event.text
  result.add(sim)
  for event in events:
    case event.kind
    of evStart:
      sim.events.add(event)
    of evRound:
      ## Derived by the rules; only cross-checked.
      if event.round != sim.round or event.cards != sim.recordIds():
        raise newException(TribunalError,
          "round " & $event.round & " does not match the seeded re-derivation")
      if sim.events.len == 0 or sim.events[^1].kind != evRound:
        sim.events.add(event)
    of evArgue:
      sim.applyArgument(event.seat, event.cards, event.text, event.notes,
        event.scripted)
    of evWhisper:
      sim.applyWhisper(event.seat, event.text, event.lean, event.notes,
        event.scripted)
    of evVote:
      ## A vote in the argument phase means the deadline called the ballot.
      sim.beginDeadlineBallot()
      sim.applyVote(event.seat, event.vote, event.text, event.notes,
        event.scripted)
    of evVerdict:
      ## Produced by the third vote; the recorded copy is only mirrored.
      if sim.events.len == 0 or sim.events[^1].kind notin {evVerdict, evEnd}:
        sim.events.add(event)
    of evEnd:
      if not sim.done:
        sim.reason = event.text
        sim.settle()
    result.add(sim)

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.round >= 0:
    result["round"] = %event.round
  if event.seat >= 0:
    result["seat"] = %event.seat
  if event.role >= 0:
    result["role"] = %event.role
  if event.cards.len > 0:
    var cards = newJArray()
    for id in event.cards:
      cards.add(%id)
    result["cards"] = cards
  if event.lean.len > 0:
    result["lean"] = %event.lean
  if event.vote.len > 0:
    result["vote"] = %event.vote
  if event.verdict.len > 0:
    result["verdict"] = %event.verdict
  if event.truth.len > 0:
    result["truth"] = %event.truth
  if event.votes.len > 0:
    var votes = newJArray()
    for vote in event.votes:
      votes.add(%vote)
    result["votes"] = votes
  if event.notes.len > 0:
    result["notes"] = %event.notes
  if event.kind in {evArgue, evWhisper, evVote}:
    result["scripted"] = %event.scripted
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    role: node{"role"}.getInt(-1),
    text: node{"text"}.getStr(""),
    lean: node{"lean"}.getStr(""),
    vote: node{"vote"}.getStr(""),
    verdict: node{"verdict"}.getStr(""),
    truth: node{"truth"}.getStr(""),
    notes: node{"notes"}.getStr(""),
    scripted: node{"scripted"}.getBool(false)
  )
  if node.hasKey("cards"):
    for id in node["cards"]:
      result.cards.add(id.getStr())
  if node.hasKey("votes"):
    for vote in node["votes"]:
      result.votes.add(vote.getStr())
