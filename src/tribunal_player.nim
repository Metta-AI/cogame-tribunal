## Tribunal player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a default
## strategy covering both roles), then idles until the final frame. All of the
## actual decision making happens inside the game server, which sends this
## seat's prompt to Claude every round.
##
## PLAYER_SCRIPTED=tally (or 1) registers the seat as the built-in
## truth-tracking baseline instead; PLAYER_SCRIPTED=hedge as the
## card-counting one. The server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <tribunal-image> --name my-tribunal \
##     --run /bin/tribunal-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Your role is dealt by the seed; read it from your prompt before you act.
If you are an ADVOCATE: pick the two strongest cards in your hand that help
you and lead with them; keep a card that hurts you unless the other side has
already made it unavoidable, and if you must, introduce it yourself and frame
it. Say in your notes which of your cards you are sitting on. Argue about
what the record actually shows, name cards by id, and in the closing round
tell the jury how to count. If the other side holds many cards and has shown
few, say so out loud.
If you are a JUROR: weigh cards, not confidence. Add up strength for guilt
and for innocence separately and write the running totals in your notes. Then
correct for what you are NOT being shown: a side holding six cards and
showing one is hiding five that hurt it, and the missing cards point the
other way. Discount an argument that asserts without citing a card id.
Whisper your counts to the other jurors and say what would change your mind;
being persuaded is not the job, being right is.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "tribunal player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "tribunal player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky RAISES on a close frame or a truncated read (only a timeout
  ## returns none), and the game's quit(0) can outrun the flushed final
  ## frame — so a dead socket must be an ordinary exit, not a crash, or the
  ## certifier reports "Player container exited with status 1".
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "tribunal player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "tribunal player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
            " (", payload{"role"}.getStr(), ")"
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "tribunal player: final scores ", payload{"scores"},
            " verdict ", payload{"verdict"}
          break
        else:
          discard
      except CatchableError as error:
        echo "tribunal player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "tribunal player: socket closed (", error.msg, "), exiting"
  try:
    socket.close()
  except CatchableError:
    discard
