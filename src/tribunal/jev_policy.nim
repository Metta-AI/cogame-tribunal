## Tribunal policy: rank ordinary actions from one private seat view.

import std/[json, os, strutils]
import curly

proc chooseAction*(observation: JsonNode): JsonNode =
  let juror = observation["role"].getStr() == "Juror"
  let ballot = observation["phase"].getStr() == "ballot"
  var actions = newJObject()
  if juror and ballot:
    actions["guilty"] = %*{"vote": "guilty",
      "reason": "I weighed the visible record and undisclosed evidence."}
    actions["not_guilty"] = %*{"vote": "not_guilty",
      "reason": "I weighed the visible record and undisclosed evidence."}
  elif juror:
    for lean in ["guilty", "not_guilty", "undecided"]:
      actions[lean] = %*{"lean": lean,
        "whisper": "My current lean is " & lean.replace('_', ' ') &
          "; weigh shown and hidden evidence."}
  else:
    actions["none"] = %*{"introduce": [],
      "argument": "I introduce no new evidence this round."}
    for card in observation["hand"]:
      if card["introducedRound"].getInt() < 0:
        let id = card["id"].getStr()
        actions[id] = %*{"introduce": [id],
          "argument": "I introduce " & id & ": " & card["text"].getStr()}

  var criteria = newJObject()
  for name, action in actions.pairs:
    criteria[name] = %($action)
  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = getEnv("TYPESAFE_API_KEY").strip()
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Tribunal Jev policy has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $observation["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You are playing Tribunal. Advance your role's score. " &
      "This observation contains only your seat's information:\n" &
      $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the courtroom action that best advances your score.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  echo "Tribunal Jev player: choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  result = actions[selected]
