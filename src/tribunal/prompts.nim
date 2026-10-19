## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "tribunal-rules-v1"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc roleIntroduction*(selection: PromptSelection, name, role: string): string =
  case selection.selectedVariant
  of pvCanonical:
    "You are " & name & ", " & role & " in a tribunal of five cogs: a " &
      "prosecutor, a defender and a jury of three. "
  of pvPlain:
    "Five cogs form this tribunal: a prosecutor, a defender and three jurors. " &
      "You are " & name & ", " & role & ". "
  of pvNumbered:
    "Tribunal: five cogs. Roles: a prosecutor, a defender and a jury of three. " &
      "Your identity: " & name & ". Your role: " & role & ". "
  of pvQuestions:
    "Who participates? Five cogs: a prosecutor, a defender and three jurors. " &
      "Who are you? " & name & ", " & role & ". "
  of pvReordered:
    "A prosecutor and a defender appear before three jurors in this five-cog " &
      "tribunal. Your cog is " & name & ", " & role & ". "
  of pvHeldoutBriefing:
    "Your briefing: this tribunal has five cogs, comprising a prosecutor, a " &
      "defender and three jurors. You play " & name & ", " & role & ". "
  of pvHeldoutReference:
    "Tribunal roster: prosecutor, defender, three jurors (five cogs total). " &
      "Your assignment: " & name & ", " & role & ". "
  of pvMixed:
    raise newException(Defect, "mixed selection must resolve to a wording")

