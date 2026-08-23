import std/[json, strutils]

const ExpectedPlayers = 5
  ## Tribunal seats exactly five cogs: a prosecutor, a defender and a jury of
  ## three. `sim.Seats` is the same number; this copy exists only so the
  ## config validator does not have to import the rules.

type
  TribunalError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    rounds*: int          ## argument rounds before the sealed ballot
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  EvidenceCard* = object
    ## One of the twelve cards in the deck. `points` is the direction the
    ## card argues, NOT the hidden truth: an advocate holds cards that hurt
    ## it, and only the cards it introduces ever reach the jury.
    id*: string             ## "E1" .. "E12"
    kind*: string           ## fingerprint, ledger entry, ...
    strength*: int          ## 1..3
    points*: string         ## "guilt" | "innocence"
    text*: string
    holder*: int            ## 0 = prosecutor, 1 = defender
    introducedRound*: int   ## -1 while still held

  RecordEntry* = object
    ## A card that has been introduced, in introduction order.
    card*: EvidenceCard
    round*: int
    side*: int              ## 0 = prosecution, 1 = defence
    seat*: int

  EventKind* = enum
    evStart = "start"
    evRound = "round"
    evArgue = "argue"
    evWhisper = "whisper"
    evVote = "vote"
    evVerdict = "verdict"
    evEnd = "end"

  GameEvent* = object
    ## Flat, so the replay JSON is one shape per event kind.
    kind*: EventKind
    round*: int          ## round/argue/whisper: the round; vote/verdict: rounds; end: rounds played
    seat*: int           ## argue/whisper/vote: the acting seat; -1 otherwise
    role*: int           ## the acting seat's role id; -1 otherwise
    cards*: seq[string]  ## round: the record at open; argue: the ids introduced
    text*: string        ## argue: the argument; whisper: the whisper; vote: the reason;
                         ## verdict: the reveal line; round: "closing"; end: the reason
    lean*: string        ## whisper only
    vote*: string        ## vote only
    verdict*: string     ## verdict only
    truth*: string       ## verdict only — the FIRST time the truth appears anywhere
    votes*: seq[string]  ## verdict only, by juror index
    notes*: string       ## argue/whisper/vote: the seat's notes after the reply
    scripted*: bool      ## argue/whisper/vote: decided by a scripted baseline

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    rounds: 4,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 400,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 900,
    llmTimeoutSeconds: 45
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(TribunalError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("rounds"):
    config.rounds = node["rounds"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()
  if config.rounds < 2:
    raise newException(TribunalError, "rounds must be at least 2")
  if config.players.len != ExpectedPlayers:
    raise newException(TribunalError,
      "tribunal needs exactly " & $ExpectedPlayers & " players")
