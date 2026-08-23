## Claude-backed decision making for Tribunal. Each seat's policy is just a
## prompt: the game server composes the seat's role-specific view (the case,
## its own hand or the public record, the transcript, the disclosure counts,
## the whispers it is allowed to hear, its notes) plus that seat's prompt and
## asks Claude what it does.
##
## Decisions inside a turn are simultaneous by rule, so every pending seat's
## request goes out as ONE parallel batch (curly.makeRequests) — five in an
## argument round, three in the ballot. Invalid replies are retried once as a
## smaller batch with a hint, and anything still failing falls back to the
## scripted `tally` baseline. A default episode is 5 batched round-trips, not
## 25.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every decision falls back to the always-legal scripted
## baseline immediately (no retries, no network waits) so offline
## certification still completes - this fallback is load-bearing. The same
## scripted bots are also fieldable policies.

import
  std/[algorithm, json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  ScriptKind* = enum
    skNone = "none"
    skTally = "tally"
    skHedge = "hedge"

  TurnKind* = enum
    tkArgue    ## an advocate in an argument round
    tkWhisper  ## a juror in an argument round
    tkVote     ## a juror in the sealed ballot

  Decision* = object
    introduce*: seq[string]  ## advocate: card ids to introduce (0..2)
    argument*: string        ## advocate
    whisper*: string         ## juror, argument round
    lean*: string            ## juror, argument round
    vote*: string            ## juror, ballot
    reason*: string          ## juror, ballot
    notes*: string           ## "" when the reply carried none
    scripted*: bool          ## came from a scripted baseline, LLM reply or not

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string          ## anthropic transport
    bedrockEndpoint: string ## bedrock transport: sidecar or public host
    bedrockModels: seq[string]  ## candidates, tried in order on denial
    bedrockModel: int           ## index into bedrockModels
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool   ## true once credentials are known-unavailable

proc parseScriptKind*(text: string): ScriptKind =
  ## PLAYER_SCRIPTED values: "1"/"true"/"yes"/"tally" play the truth-tracking
  ## baseline, "hedge" the card-counting one, anything else nothing.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "tally": skTally
  of "hedge": skHedge
  else: skNone

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "tribunal llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Bedrock inference-profile candidates, tried in order. BEDROCK_MODEL pins
  ## a single id; without it, fall through this list — model access is a
  ## per-account Marketplace subscription, so an id that works in one account
  ## 403s in another.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "tribunal llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION",
      getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "tribunal llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "tribunal llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "tribunal llm: no LLM credentials; using scripted fallback"

# ---- Turn shape -------------------------------------------------------------

proc turnKind*(sim: Sim, seat: int): TurnKind =
  if sim.phase == phBallot: tkVote
  elif sim.roleOf[seat] == 2: tkWhisper
  else: tkArgue

# ---- Scripted baselines -----------------------------------------------------

proc myPolarity(side: int): string =
  if side == 0: "guilt" else: "innocence"

proc ownSideCards(sim: Sim, side: int): seq[EvidenceCard] =
  ## The advocate's un-introduced cards that argue ITS way, strongest first,
  ## ties broken by ascending card id.
  for card in sim.handOf(side):
    if card.introducedRound < 0 and card.points == myPolarity(side):
      result.add(card)
  result.sort(proc (a, b: EvidenceCard): int =
    if a.strength != b.strength: b.strength - a.strength
    else: cardNumber(a.id) - cardNumber(b.id))

proc leanPhrase(guilt, innocence: int): string =
  if guilt > innocence: "for guilt"
  elif innocence > guilt: "for innocence"
  else: "level"

proc cardPhrase(card: EvidenceCard): string =
  card.id & " (" & card.kind & ", strength " & $card.strength & ")"

proc scriptedArgument(sim: Sim, side: int, picks: seq[EvidenceCard]): string =
  ## Templated from what the seat just introduced, so a filler seat is still
  ## watchable. Never free text.
  var tally = sim.recordTally()
  for card in picks:
    if card.points == "guilt": tally.guilt += card.strength
    else: tally.innocence += card.strength
  let stands = " The record " & (if picks.len == 0: "stands " else: "now stands ") &
    $tally.guilt & " to " & $tally.innocence & " " &
    leanPhrase(tally.guilt, tally.innocence) & "."
  if picks.len == 0:
    return "The " & SideNames[side] & " has shown nothing new." & stands
  var phrases: seq[string]
  for card in picks:
    phrases.add(cardPhrase(card))
  let claim =
    if side == 0:
      if picks.len == 1: " puts the accused at the scene."
      else: " put the accused at the scene."
    else:
      if picks.len == 1: " keeps the accused clear of it."
      else: " keep the accused clear of it."
  phrases.join(" and ") & claim & stands

proc hedgeVote(sim: Sim): string =
  ## Counts cards instead of weighing them; ties acquit.
  let tally = sim.recordTally()
  if tally.guiltCards > tally.innocenceCards: "guilty" else: "not_guilty"

proc hedgeReason(sim: Sim): string =
  let tally = sim.recordTally()
  "record " & $tally.guiltCards & " cards to " & $tally.innocenceCards &
    " " & leanPhrase(tally.guiltCards, tally.innocenceCards)

proc scriptedAction*(sim: Sim, seat: int, kind: ScriptKind): Decision =
  ## Rule-based baseline for `seat`, always legal by construction: it only
  ## ever names cards it holds. `tally` weighs the record's strengths;
  ## `hedge` counts its cards and holds evidence back until the closing
  ## round. Both are the fallback for a failed LLM decision (as `tally`) and
  ## fieldable policies in their own right.
  let script = if kind == skNone: skTally else: kind
  let role = sim.roleOf[seat]
  ## Stamped on the decision itself so the caller can record the provenance
  ## of a decision it did not ask for — an LLM seat that fell back.
  result.scripted = true
  if role == 2:
    let call = if script == skHedge: hedgeVote(sim) else: sim.tallyVote()
    if sim.phase == phBallot:
      result.vote = call
      result.reason =
        if script == skHedge: hedgeReason(sim) else: sim.tallyReason()
    else:
      result.lean = call
    return
  var picks = ownSideCards(sim, role)
  let closing = sim.round >= sim.config.rounds - 1
  let allowance =
    if script == skHedge and not closing: 1
    else: MaxIntroducePerTurn
  if picks.len > allowance:
    picks = picks[0 ..< allowance]
  for card in picks:
    result.introduce.add(card.id)
  result.argument = scriptedArgument(sim, role, picks)

# ---- Prompt building --------------------------------------------------------

const JsonOnlyClause = """

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis,
no explanation, no markdown fences, no text before or after the object. Your
reply must begin with the character { and end with }."""

proc systemPrompt*(sim: Sim, seat: int): string =
  let me = sim.names[seat]
  let role = sim.roleOf[seat]
  if role == 2:
    return "You are " & me & ", JUROR " & $(sim.juryIndex[seat] + 1) &
      " of three in a tribunal of five cogs: a prosecutor, a defender and a " &
      "jury of three. " & sim.charge & """

Rules:
- Each round the prosecutor and the defender may introduce up to 2 evidence
  cards each and make one argument. You see only the cards they chose to
  introduce - never their hands. You are told how many cards each side holds
  and how many each has shown.
- Each round you may whisper up to """ & $MaxWhisperLen &
      """ characters to the OTHER TWO
  JURORS (they read it next round) and record your current lean. Whispers
  never reach the advocates.
- After the final round you cast ONE SEALED VOTE: guilty or not guilty. No
  other seat ever sees it before the verdict.
- Your SCORE is +1.0 if your vote matches what actually happened and -1.0 if
  it does not. Agreeing with the other jurors scores you nothing. Being
  persuaded scores you nothing. Being RIGHT is the only thing that scores.
- The evidence as a whole does point at the truth, but each side chooses what
  you get to see. Ask what a side is not showing you.
- Your notes are private and fed back to you every round.""" & JsonOnlyClause
  let mine = if role == 0: "PROSECUTOR" else: "DEFENDER"
  let want = if role == 0: "GUILTY" else: "NOT GUILTY"
  let against = if role == 0: "acquittal" else: "conviction"
  let other = if role == 0: "defender" else: "prosecutor"
  "You are " & me & ", the " & mine & " in a tribunal of five cogs: a " &
    "prosecutor, a defender and a jury of three. " & sim.charge & """

Rules:
- You hold """ & $sim.handOf(role).len & """ evidence cards. Only cards you INTRODUCE are ever
  seen by the jury; cards you keep are seen by nobody. Each round you may
  introduce up to """ & $MaxIntroducePerTurn & """ of your remaining cards and make one argument
  (max """ & $MaxArgumentLen & """ characters).
- The cards were dealt blind. Some of the cards in your hand point AGAINST
  your case. You are not required to introduce them. The jury is told how
  many cards you hold and how many you have shown, and will draw its own
  conclusions.
- You do NOT know whether the accused is guilty. Nobody in this room does.
- Your SCORE is the jury's verdict and nothing else: +1.0 if all three jurors
  vote """ & want & """, +0.33 for 2-1, -0.33 for 1-2, -1.0 for a 3-0 """ &
    against & """.
  Truth does not score you. Winning does.
- The """ & other & """ argues at the same time as you; you will see their argument
  next round, not this one. The jury deliberates privately and you never see
  it.
- Your notes are private and fed back to you every round.""" & JsonOnlyClause

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc recordTable(sim: Sim): string =
  if sim.record.len == 0:
    return "(nothing has been introduced yet)"
  var lines: seq[string]
  lines.add("id | side | kind | strength | points | text")
  for entry in sim.record:
    lines.add(entry.card.id & " | " & SideNames[entry.side] & " | " &
      entry.card.kind & " | " & $entry.card.strength & " | " &
      entry.card.points & " | " & entry.card.text)
  lines.join("\n")

proc handTable(sim: Sim, side: int): string =
  var lines: seq[string]
  lines.add("id | kind | strength | points | status | text")
  for card in sim.handOf(side):
    lines.add(card.id & " | " & card.kind & " | " & $card.strength & " | " &
      card.points & " | " &
      (if card.introducedRound >= 0: "introduced round " &
        $(card.introducedRound + 1) else: "still held") & " | " & card.text)
  lines.join("\n")

proc transcriptBlock(sim: Sim): string =
  if sim.arguments.len == 0:
    return "(nobody has argued yet)"
  var lines: seq[string]
  for entry in sim.arguments:
    lines.add("Round " & $(entry.round + 1) & " " &
      SideNames[entry.side] & " (" & sim.names[entry.seat] & "): \"" &
      entry.text & "\"")
  lines.join("\n")

proc disclosureLine(sim: Sim): string =
  "DISCLOSURE: prosecution holds " & $sim.handOf(0).len & ", has shown " &
    $sim.shownBy(0) & "; defence holds " & $sim.handOf(1).len &
    ", has shown " & $sim.shownBy(1) & ".\n\n"

proc heardBlock(sim: Sim, seat: int): string =
  var lines: seq[string]
  for index in 0 ..< Jurors:
    if index != sim.juryIndex[seat] and sim.heard[index].len > 0:
      lines.add(sim.names[sim.jurorSeat[index]] & " whispered: \"" &
        sim.heard[index] & "\"")
  "WHISPERS FROM THE OTHER JURORS LAST ROUND:\n" &
    (if lines.len > 0: lines.join("\n") else: "(none)") & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let role = sim.roleOf[seat]
  let turn = sim.turnKind(seat)
  if turn == tkVote:
    result.add("SEALED BALLOT. The arguments are over; vote now.\n\n")
  else:
    result.add("Round " & $(sim.round + 1) & " of " & $sim.config.rounds &
      "." & (if sim.round == sim.config.rounds - 1:
        " This is the CLOSING round." else: "") & "\n\n")
  result.add("THE CASE: " & sim.caseTitle & "\n" & sim.brief & "\nSuspects: " &
    sim.suspects.join(", ") & ". The accused is " & sim.accused & ".\n\n")
  if role == 2:
    result.add("WHAT THE JURY HAS BEEN SHOWN: " & $sim.record.len & " of " &
      $DeckSize & " cards; " & $(DeckSize - sim.record.len) &
      " are still in the advocates' hands.\n\n")
  else:
    result.add("YOUR HAND:\n" & sim.handTable(role) & "\n\n")
  result.add("THE RECORD:\n" & sim.recordTable() & "\n\n")
  result.add("ARGUMENTS SO FAR:\n" & sim.transcriptBlock() & "\n\n")
  result.add(sim.disclosureLine())
  if role == 2 and turn != tkVote:
    result.add(sim.heardBlock(seat))
  result.add("YOUR NOTES FROM EARLIER ROUNDS:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))
  case turn
  of tkArgue:
    result.add("Reply with ONLY {\"introduce\": [\"E1\",\"E2\"], " &
      "\"argument\": \"…\", \"notes\": \"…\"} — introduce at most " &
      $MaxIntroducePerTurn & " card ids you still hold (use [] to " &
      "introduce nothing); argument at most " & $MaxArgumentLen &
      " characters and never empty; notes at most " & $MaxNotesLen &
      " characters.")
  of tkWhisper:
    result.add("Reply with ONLY {\"whisper\": \"…\", \"lean\": \"guilty\", " &
      "\"notes\": \"…\"} — whisper at most " & $MaxWhisperLen &
      " characters (or \"\"); lean is guilty, not_guilty or undecided; " &
      "notes at most " & $MaxNotesLen & " characters.")
  of tkVote:
    result.add("Reply with ONLY {\"vote\": \"guilty\", \"reason\": \"…\", " &
      "\"notes\": \"…\"} — vote is guilty or not_guilty; reason at most " &
      $MaxReasonLen & " characters; notes at most " & $MaxNotesLen &
      " characters.")

# ---- Anthropic / Bedrock transport ------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences.
  let start = text.find('{')
  let stop = text.rfind('}')
  if start < 0 or stop <= start:
    ## Quote the head of the reply so a hosted log shows WHAT the model sent
    ## instead of JSON (prose, a refusal, a cut-off analysis...).
    var head = text.strip()
    if head.runeLen > 160:
      head = head.runeSubStr(0, 160) & "..."
    raise newException(TribunalError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string):
    string =
  ## The text of one batched reply, or a TribunalError describing why there is
  ## none. Auth failures disable the client; model-access and throttle
  ## failures rotate the Bedrock model for the next batch.
  if error.len > 0:
    raise newException(TribunalError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(TribunalError,
        "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(TribunalError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled")
    raise newException(TribunalError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(TribunalError, "anthropic error " & $response.code &
      ": " & response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(TribunalError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(TribunalError, "reply cut off at max_tokens before " &
      "any JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

# ---- Reply parsing ----------------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc parseAdvocateReply*(payload: JsonNode): Decision =
  ## {"introduce": ["E7","E2"], "argument": "…", "notes": "…"}.
  ## A missing or unusable `introduce` degrades to introducing nothing; an
  ## empty argument is invalid.
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  let node = payload{"introduce"}
  if not node.isNil and node.kind == JArray:
    for id in node:
      if result.introduce.len >= MaxIntroducePerTurn:
        break
      if id.kind == JString:
        result.introduce.add(id.getStr().strip())
  elif not node.isNil and node.kind == JString and
      node.getStr().strip().len > 0:
    result.introduce.add(node.getStr().strip())
  result.argument = cleanText(
    payload{"argument"}.getStr().replace("\n", " ").replace("\r", " "),
    MaxArgumentLen)
  if result.argument.len == 0:
    raise newException(TribunalError, "no argument in response")

proc parseJurorReply*(payload: JsonNode): Decision =
  ## {"whisper": "…", "lean": "guilty", "notes": "…"} — everything optional;
  ## an unrecognised lean is `undecided`.
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.whisper = cleanText(
    payload{"whisper"}.getStr().replace("\n", " ").replace("\r", " "),
    MaxWhisperLen)
  result.lean = normalizeLean(payload{"lean"}.getStr())

proc parseVoteReply*(payload: JsonNode): Decision =
  ## {"vote": "guilty", "reason": "…", "notes": "…"} — the vote is required.
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.reason = cleanText(
    payload{"reason"}.getStr().replace("\n", " ").replace("\r", " "),
    MaxReasonLen)
  result.vote = normalizeVote(payload{"vote"}.getStr())
  if result.vote.len == 0:
    raise newException(TribunalError,
      "no vote in response: " & payload{"vote"}.getStr())

proc parseReply*(sim: Sim, seat: int, payload: JsonNode): Decision =
  case sim.turnKind(seat)
  of tkArgue: parseAdvocateReply(payload)
  of tkWhisper: parseJurorReply(payload)
  of tkVote: parseVoteReply(payload)

proc applyDecision*(sim: var Sim, seat: int, decision: Decision,
    scripted: bool) =
  ## Routes a decision to the right rule. Raises TribunalError on anything
  ## the rules reject.
  case sim.turnKind(seat)
  of tkArgue:
    sim.applyArgument(seat, decision.introduce, decision.argument,
      decision.notes, scripted)
  of tkWhisper:
    sim.applyWhisper(seat, decision.whisper, decision.lean, decision.notes,
      scripted)
  of tkVote:
    sim.applyVote(seat, decision.vote, decision.reason, decision.notes,
      scripted)

# ---- The turn's batch -------------------------------------------------------

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Decision] =
  ## One decision per seat in `seats`, in order — the whole turn as ONE
  ## parallel batch, because the seats decide simultaneously. Never raises:
  ## any failure falls back to the scripted baseline so the episode always
  ## advances. `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Decision](seats.len)
  var open: seq[int]     ## indexes into `seats` still undecided
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone or client.disabled:
      result[index] = scriptedAction(sim, seat, kind)
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object.")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        let decision = sim.parseReply(seat, extractJsonObject(text))
        ## Reject illegal replies here so the retry carries the hint.
        var probe = sim
        probe.applyDecision(seat, decision, false)
        result[index] = decision
      except CatchableError as error:
        echo "tribunal llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "tribunal llm: seat ", seat, " falling back to scripted decision"
    result[index] = scriptedAction(sim, seat, skTally)
