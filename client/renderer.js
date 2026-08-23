// Tribunal shared renderer + drivers.
//
// One canvas scene — a courtroom: the bench across the top with the case
// title, the accused's name plate and the four suspects; the PROSECUTION
// podium on the left and the DEFENCE podium on the right, each with its cog,
// its disclosure readout (HOLDS 4 · SHOWN 3) and its argument as a speech
// bubble; the evidence table in the middle, twelve card slots where held
// cards are face-down paper backs edged in their holder's colour and an
// introduced card flips face-up on its `argue` event; the jury box below it,
// three cogs whose tipping scales show their lean while the ballot is sealed;
// and along the bottom the scales of evidence, the record's guilt strength
// against its innocence strength. On the verdict three envelopes flip open,
// the bench stamps the verdict, and a spotlight sweeps to the real culprit.
//
// Fed by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle). All
// state derivation happens server-side / wasm-side; this file only draws
// state objects:
//   {case:{title,accused,charge,brief,suspects[4]},
//    seats:[{name,role,roleId,juryIndex,score,handCount,held,introduced,
//            argument,whisper,lean,vote|null,voteReason,notes,pending,
//            scripted} ×5 by SEAT],
//    roleSeat:{prosecutor,defender,jurors[3]},
//    record:[{id,side,seat,round,kind,strength,points,text}],
//    transcript:[{round,side,seat,name,text}],
//    whispers:[{round,juror,seat,name,text,lean}],
//    tally:{guilt,innocence,guiltCards,innocenceCards},
//    round,rounds,roundsPlayed,phase:"argument|ballot|verdict|done",
//    votes[3]|nulls, sealed, verdict, truth, culprit, correctJurors,
//    gameDone, reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Seats are
  // red, blue, green, yellow, violet — five seats, five sprites.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var GUILT = "#e0523a";
  var INNOCENCE = "#3f7cc4";
  var CARD_BACK = "#8d7a5e";
  var CARD_BACK_EDGE = "#57452c";
  var STRIP = "rgba(242, 232, 216, 0.06)";
  var SIDE_TAGS = ["PROSECUTION", "DEFENCE"];
  var SIDE_WORDS = ["prosecution", "defence"];
  var ROLE_TAGS = ["PROS", "DEF", "JUROR"];
  // Timing: a card flips, an argument bubble pops, the reveal unfolds.
  var SLIDE_MS = 700;
  var SLIP_MS = 900;
  var BUBBLE_HOLD_MS = 6000;
  var ENVELOPE_MS = 900;
  var STAMP_MS = 1500;
  var SPOTLIGHT_MS = 2300;
  var COMPACT_W = 560;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "soldier_violet_front.png", "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function score1(value) {
    var n = typeof value === "number" ? value : 0;
    return (n > 0 ? "+" : "") + n.toFixed(1);
  }

  function verdictWord(verdict) {
    return verdict === "guilty" ? "GUILTY" :
      verdict === "not_guilty" ? "NOT GUILTY" : "";
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function polarityHex(points) {
    return points === "guilt" ? GUILT : INNOCENCE;
  }

  // ---- Layout --------------------------------------------------------------

  // Bench across the top; podiums down the two sides; the evidence table and
  // the jury box stacked in the middle; the scales of evidence along the
  // bottom. Everything is measured from the canvas so the scene scales to
  // whatever frame the viewer is embedded in, down to 360px wide.
  function computeLayout(width, height) {
    var margin = 8;
    var compact = width < COMPACT_W;
    var benchH = Math.max(58, Math.min(height * 0.19, 118));
    var scalesH = Math.max(46, Math.min(height * 0.13, 86));
    var mainTop = benchH + margin;
    var mainH = Math.max(80, height - benchH - scalesH - margin * 2);
    var podiumW = Math.max(96, Math.min(width * 0.26, 210));
    var centerX = margin + podiumW;
    var centerW = Math.max(120, width - 2 * (margin + podiumW));
    var juryH = Math.max(74, mainH * 0.36);
    var cardsH = Math.max(60, mainH - juryH);
    var scale = Math.max(0.62, Math.min(1.25, width / 960));
    return {
      width: width, height: height, margin: margin, compact: compact,
      scale: scale,
      bench: { x: margin, y: margin, w: width - 2 * margin, h: benchH - margin },
      left: { x: margin, y: mainTop, w: podiumW, h: mainH },
      right: { x: width - margin - podiumW, y: mainTop, w: podiumW, h: mainH },
      cards: { x: centerX, y: mainTop, w: centerW, h: cardsH },
      jury: { x: centerX, y: mainTop + cardsH, w: centerW, h: juryH },
      scales: { x: margin, y: height - scalesH, w: width - 2 * margin,
        h: scalesH - margin }
    };
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    if (!w || !h) return;
    var L = computeLayout(w, h);
    var seats = view.seats || [];
    var roleSeat = view.roleSeat || {};
    var fx = view.effects || {};
    var now = view.now || Date.now();

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.5)";
    ctx.fillRect(0, 0, w, h);

    drawBench(ctx, L, view, now, fx);

    var prosecutor = typeof roleSeat.prosecutor === "number" ?
      roleSeat.prosecutor : 0;
    var defender = typeof roleSeat.defender === "number" ?
      roleSeat.defender : 1;
    drawPodium(ctx, images, L, L.left, 0, prosecutor, seats[prosecutor], view,
      now, fx);
    drawPodium(ctx, images, L, L.right, 1, defender, seats[defender], view,
      now, fx);

    drawEvidenceTable(ctx, L, view, now, fx);
    drawJuryBox(ctx, images, L, view, now, fx);
    drawScales(ctx, L, view);

    if (view.verdict && fx.revealAt) {
      drawReveal(ctx, L, view, now, fx);
    }
  }

  function panel(ctx, rect, radius) {
    ctx.save();
    ctx.fillStyle = STRIP;
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, radius);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.10)";
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.restore();
  }

  function drawBench(ctx, L, view, now, fx) {
    var rect = L.bench;
    var scale = L.scale;
    var info = view.case || {};
    panel(ctx, rect, 8 * scale);
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    ctx.font = "700 " + Math.round(15 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.fillText(ellipsize(ctx, info.title || "THE CASE", rect.w - 20),
      rect.x + rect.w / 2, rect.y + 4 * scale);

    ctx.font = "600 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("THE ACCUSED", rect.x + rect.w / 2, rect.y + 22 * scale);
    ctx.font = "700 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = AMBER;
    ctx.fillText(ellipsize(ctx, info.accused || "—", rect.w - 20),
      rect.x + rect.w / 2, rect.y + 32 * scale);
    ctx.restore();

    // The four suspects, as small cards along the bottom of the bench.
    var suspects = info.suspects || [];
    if (suspects.length) {
      var cw = Math.min(rect.w / suspects.length - 6, 150 * L.scale);
      var top = rect.y + rect.h - 20 * scale;
      var total = suspects.length * (cw + 6) - 6;
      var x0 = rect.x + (rect.w - total) / 2;
      for (var i = 0; i < suspects.length; i++) {
        var x = x0 + i * (cw + 6);
        var isCulprit = view.culprit && suspects[i] === view.culprit;
        var isAccused = suspects[i] === info.accused;
        ctx.save();
        ctx.fillStyle = isCulprit ? rgba(AMBER, 0.9) : "rgba(242,232,216,0.10)";
        roundRect(ctx, x, top, cw, 17 * scale, 3 * scale);
        ctx.fill();
        if (isAccused) {
          ctx.strokeStyle = rgba(AMBER, 0.8);
          ctx.lineWidth = 1.5;
          ctx.stroke();
        }
        ctx.font = "600 " + Math.round(10 * scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.fillStyle = isCulprit ? INK : PAPER_DIM;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(ellipsize(ctx, suspects[i], cw - 8), x + cw / 2,
          top + 9 * scale);
        ctx.restore();
      }
    }

    // The verdict stamp lands on the bench.
    if (view.verdict && fx.revealAt) {
      var age = now - fx.revealAt;
      if (age > ENVELOPE_MS) {
        var t = Math.min(1, (age - ENVELOPE_MS) / 320);
        ctx.save();
        ctx.translate(rect.x + rect.w / 2, rect.y + rect.h * 0.52);
        ctx.rotate(-0.14);
        ctx.globalAlpha = 0.55 + 0.45 * t;
        ctx.scale(1 + (1 - t) * 1.4, 1 + (1 - t) * 1.4);
        ctx.font = "700 " + Math.round(30 * L.scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.lineWidth = 3;
        ctx.strokeStyle = view.verdict === "guilty" ? GUILT : INNOCENCE;
        ctx.fillStyle = rgba(view.verdict === "guilty" ? GUILT : INNOCENCE,
          0.22);
        var word = verdictWord(view.verdict);
        ctx.fillText(word, 0, 0);
        ctx.strokeText(word, 0, 0);
        ctx.restore();
      }
    }
  }

  function drawPodium(ctx, images, L, rect, side, seatIndex, seat, view, now,
      fx) {
    var scale = L.scale;
    panel(ctx, rect, 8 * scale);
    if (!seat) return;
    var color = seatColor(seatIndex);
    var size = Math.max(30, Math.min(rect.w * 0.5, rect.h * 0.26, 84));
    var cx = rect.x + rect.w / 2;
    var cogY = rect.y + rect.h * 0.34;

    drawTag(ctx, cx, rect.y + 12 * scale, SIDE_TAGS[side], COLOR_HEX[color],
      scale);

    var sprite = images["soldier_" + color + "_front.png"];
    ctx.save();
    ctx.translate(cx, cogY);
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();

    if (seat.pending && !view.done) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 3;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(cx, cogY, size * 0.6, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    ctx.font = "600 " + Math.round(12 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    ctx.fillText(ellipsize(ctx, seat.name || "", rect.w - 10), cx,
      cogY + size * 0.62 + 4 * scale);
    ctx.shadowColor = "transparent";
    ctx.font = "700 " + Math.round(15 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = view.verdict ?
      ((seat.score || 0) > 0 ? AMBER : PAPER_DIM) : GHOST;
    ctx.fillText(score1(seat.score), cx, cogY + size * 0.62 + 19 * scale);
    ctx.font = "600 " + Math.round(9.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("HOLDS " + (seat.held || 0) + " · SHOWN " +
      (seat.introduced || 0), cx, cogY + size * 0.62 + 36 * scale);
    ctx.restore();

    // The argument, as a speech bubble over the podium.
    var text = (fx.lastArgument && fx.lastArgument[seatIndex]) || seat.argument;
    if (text) {
      var at = fx.argueAt ? fx.argueAt[seatIndex] : null;
      var age = typeof at === "number" ? now - at : BUBBLE_HOLD_MS;
      var alpha = age < BUBBLE_HOLD_MS ? 1 :
        Math.max(0.4, 1 - (age - BUBBLE_HOLD_MS) / 4000);
      drawBubble(ctx, cx, rect.y + rect.h - 6 * scale, text,
        rect.w - 8, scale, alpha);
    }
  }

  // Twelve slots: the introduced cards face-up in introduction order, then
  // the still-held cards as face-down backs edged in their holder's colour.
  function drawEvidenceTable(ctx, L, view, now, fx) {
    var rect = L.cards;
    var scale = L.scale;
    panel(ctx, rect, 6 * scale);
    ctx.save();
    ctx.font = "700 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("EVIDENCE", rect.x + 6 * scale, rect.y + 3 * scale);
    ctx.restore();

    var record = view.record || [];
    var seats = view.seats || [];
    var roleSeat = view.roleSeat || {};
    var slots = [];
    record.forEach(function (entry) { slots.push({ card: entry }); });
    [0, 1].forEach(function (side) {
      var seatIndex = side === 0 ? roleSeat.prosecutor : roleSeat.defender;
      var seat = seats[seatIndex];
      var held = seat ? (seat.held || 0) : 0;
      for (var i = 0; i < held; i++) slots.push({ back: side });
    });
    while (slots.length < 12) slots.push({ back: -1 });
    slots = slots.slice(0, 12);

    var cols = 4;
    var rows = 3;
    var top = rect.y + 14 * scale;
    var gap = 4 * scale;
    var cw = (rect.w - gap * (cols + 1)) / cols;
    var ch = (rect.h - 16 * scale - gap * (rows + 1)) / rows;
    for (var i = 0; i < slots.length; i++) {
      var x = rect.x + gap + (i % cols) * (cw + gap);
      var y = top + Math.floor(i / cols) * (ch + gap);
      drawCard(ctx, L, x, y, cw, ch, slots[i], view, now, fx);
    }
  }

  function drawCard(ctx, L, x, y, w, h, slot, view, now, fx) {
    var scale = L.scale;
    if (!slot.card) {
      // Face-down: a paper back edged in the holder's side colour.
      ctx.save();
      ctx.fillStyle = CARD_BACK;
      roundRect(ctx, x, y, w, h, 3 * scale);
      ctx.fill();
      ctx.strokeStyle = slot.back === 0 ? GUILT :
        slot.back === 1 ? INNOCENCE : CARD_BACK_EDGE;
      ctx.lineWidth = 2;
      ctx.stroke();
      ctx.globalAlpha = 0.35;
      ctx.strokeStyle = CARD_BACK_EDGE;
      ctx.lineWidth = 1;
      for (var i = 1; i < 4; i++) {
        ctx.beginPath();
        ctx.moveTo(x + 4, y + (h / 4) * i);
        ctx.lineTo(x + w - 4, y + (h / 4) * i);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
      ctx.font = "600 " + Math.round(8 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = "rgba(42, 31, 22, 0.65)";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(slot.back >= 0 ? SIDE_WORDS[slot.back].toUpperCase() :
        "SEALED", x + w / 2, y + h / 2);
      ctx.restore();
      return;
    }
    var card = slot.card;
    var at = fx.cardAt ? fx.cardAt[card.id] : null;
    var t = typeof at === "number" ? Math.min(1, (now - at) / SLIDE_MS) : 1;
    var eased = 1 - Math.pow(1 - t, 3);
    // The flip: the card squashes horizontally through the half-way point.
    var flip = Math.abs(Math.cos(Math.min(1, eased) * Math.PI / 2));
    var faceUp = eased > 0.5 || t >= 1;
    var scaleX = faceUp ? 1 - flip * 0.0 : Math.max(0.06, flip);
    if (!faceUp) {
      ctx.save();
      ctx.translate(x + w / 2, 0);
      ctx.scale(Math.max(0.06, 1 - eased * 2), 1);
      ctx.translate(-(x + w / 2), 0);
      drawCard(ctx, L, x, y, w, h, { back: card.side }, view, now, {});
      ctx.restore();
      return;
    }
    var accent = polarityHex(card.points);
    ctx.save();
    ctx.translate(x + w / 2, 0);
    ctx.scale(scaleX, 1);
    ctx.translate(-(x + w / 2), 0);
    ctx.fillStyle = PAPER;
    roundRect(ctx, x, y, w, h, 3 * scale);
    ctx.fill();
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.fillStyle = accent;
    ctx.fillRect(x, y, 4 * scale, h);

    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.font = "700 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = INK;
    ctx.fillText(card.id, x + 8 * scale, y + 3 * scale);
    ctx.font = "600 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = "#5c4a36";
    ctx.fillText(ellipsize(ctx, card.kind || "", w - 44 * scale),
      x + 26 * scale, y + 4.5 * scale);
    // Strength as 1-3 pips.
    for (var p = 0; p < (card.strength || 0); p++) {
      ctx.fillStyle = accent;
      ctx.fillRect(x + w - (8 + p * 6) * scale, y + 5 * scale, 4 * scale,
        4 * scale);
    }
    if (!L.compact && h > 46 * scale) {
      ctx.font = Math.round(8.5 * scale) +
        "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
      ctx.fillStyle = "#4a3a2a";
      var lines = wrapLines(ctx, card.text || "", w - 14 * scale, 2);
      lines.forEach(function (line, i) {
        ctx.fillText(line, x + 8 * scale, y + (17 + i * 10) * scale);
      });
    }
    ctx.font = "600 " + Math.round(8 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = accent;
    ctx.fillText((card.points === "guilt" ? "GUILT" : "INNOCENCE") + " · " +
      SIDE_WORDS[card.side === 1 ? 1 : 0].toUpperCase(),
      x + 8 * scale, y + h - 11 * scale);
    ctx.restore();
  }

  function drawJuryBox(ctx, images, L, view, now, fx) {
    var rect = L.jury;
    var scale = L.scale;
    panel(ctx, rect, 6 * scale);
    ctx.save();
    ctx.font = "700 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("JURY", rect.x + 6 * scale, rect.y + 3 * scale);
    ctx.restore();

    var seats = view.seats || [];
    var roleSeat = view.roleSeat || {};
    var jurors = roleSeat.jurors || [];
    var votes = view.votes || [];
    var size = Math.max(24, Math.min(rect.w / 3 * 0.42, rect.h * 0.42, 68));
    for (var j = 0; j < jurors.length; j++) {
      var seatIndex = jurors[j];
      var seat = seats[seatIndex];
      if (!seat) continue;
      var cx = rect.x + rect.w * ((j + 0.5) / jurors.length);
      var cogY = rect.y + rect.h * 0.42;
      var color = seatColor(seatIndex);
      var sprite = images["soldier_" + color + "_front.png"];
      ctx.save();
      ctx.translate(cx, cogY);
      if (sprite && sprite.width) {
        ctx.imageSmoothingEnabled = false;
        ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
      } else {
        ctx.fillStyle = COLOR_HEX[color];
        ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
      }
      ctx.restore();
      if (seat.pending && !view.done) {
        ctx.save();
        ctx.strokeStyle = AMBER;
        ctx.lineWidth = 2;
        ctx.setLineDash([5, 4]);
        ctx.beginPath();
        ctx.arc(cx, cogY, size * 0.62, 0, Math.PI * 2);
        ctx.stroke();
        ctx.restore();
      }
      ctx.save();
      ctx.textAlign = "center";
      ctx.textBaseline = "top";
      ctx.font = "600 " + Math.round(11 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = PAPER;
      ctx.shadowColor = "rgba(0,0,0,0.8)";
      ctx.shadowBlur = 4;
      ctx.fillText(ellipsize(ctx, seat.name || "", rect.w / jurors.length - 8),
        cx, cogY + size * 0.62 + 3 * scale);
      ctx.restore();

      var vote = votes[j];
      if (view.verdict && fx.revealAt) {
        drawEnvelope(ctx, cx, cogY + size * 0.62 + 18 * scale, size,
          vote || seat.vote, COLOR_HEX[color], scale, now, fx.revealAt);
      } else {
        drawLeanScale(ctx, cx, cogY + size * 0.62 + 26 * scale, size * 0.9,
          seat.lean, scale);
      }

      // Whispers rise as small dim bubbles.
      var whisper = (fx.lastWhisper && fx.lastWhisper[seatIndex]) ||
        seat.whisper;
      if (whisper && !view.verdict) {
        var at = fx.whisperAt ? fx.whisperAt[seatIndex] : null;
        var age = typeof at === "number" ? now - at : BUBBLE_HOLD_MS;
        var alpha = age < BUBBLE_HOLD_MS ? 0.85 :
          Math.max(0.3, 0.85 - (age - BUBBLE_HOLD_MS) / 5000);
        drawBubble(ctx, cx, cogY - size * 0.5, whisper,
          rect.w / jurors.length - 6, scale, alpha);
      }
    }
  }

  // A little tipping scale: it leans to the juror's stated lean while the
  // ballot is sealed. Spectator-side only — no seat ever sees it.
  function drawLeanScale(ctx, cx, cy, width, lean, scale) {
    var tilt = lean === "guilty" ? -0.28 : lean === "not_guilty" ? 0.28 : 0;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.strokeStyle = lean === "guilty" ? GUILT :
      lean === "not_guilty" ? INNOCENCE : GHOST;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(0, 0);
    ctx.lineTo(0, -7 * scale);
    ctx.stroke();
    ctx.rotate(tilt);
    ctx.beginPath();
    ctx.moveTo(-width / 2, -7 * scale);
    ctx.lineTo(width / 2, -7 * scale);
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(-width / 2, -5 * scale, 2.5 * scale, 0, Math.PI * 2);
    ctx.arc(width / 2, -5 * scale, 2.5 * scale, 0, Math.PI * 2);
    ctx.fillStyle = ctx.strokeStyle;
    ctx.fill();
    ctx.restore();
  }

  function drawEnvelope(ctx, cx, top, size, vote, accent, scale, now,
      revealAt) {
    var t = Math.min(1, Math.max(0, (now - revealAt) / ENVELOPE_MS));
    var w = Math.max(46, size * 1.05);
    var h = Math.max(22, size * 0.42);
    ctx.save();
    ctx.translate(cx, top);
    ctx.fillStyle = PAPER;
    roundRect(ctx, -w / 2, 0, w, h, 2 * scale);
    ctx.fill();
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    ctx.stroke();
    // The flap opens.
    ctx.save();
    ctx.globalAlpha = 1 - t;
    ctx.beginPath();
    ctx.moveTo(-w / 2, 0);
    ctx.lineTo(0, h * 0.6);
    ctx.lineTo(w / 2, 0);
    ctx.closePath();
    ctx.fillStyle = "rgba(42,31,22,0.12)";
    ctx.fill();
    ctx.strokeStyle = rgba(accent, 0.5);
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.restore();
    if (t > 0.35 && vote) {
      ctx.globalAlpha = Math.min(1, (t - 0.35) / 0.4);
      ctx.font = "700 " + Math.round(Math.min(13, h * 0.55)) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillStyle = vote === "guilty" ? GUILT : INNOCENCE;
      ctx.fillText(verdictWord(vote), 0, h / 2);
    }
    ctx.restore();
  }

  // The scales of evidence: the record's guilt strength against its
  // innocence strength. This is the picture of the case.
  function drawScales(ctx, L, view) {
    var rect = L.scales;
    var scale = L.scale;
    var tally = view.tally || {};
    var guilt = tally.guilt || 0;
    var innocence = tally.innocence || 0;
    var total = Math.max(1, guilt + innocence);
    panel(ctx, rect, 6 * scale);
    ctx.save();
    ctx.font = "700 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("SCALES OF EVIDENCE", rect.x + 6 * scale, rect.y + 3 * scale);

    var barY = rect.y + rect.h * 0.45;
    var barH = Math.max(10, rect.h * 0.34);
    var barX = rect.x + 8 * scale;
    var barW = rect.w - 16 * scale;
    ctx.fillStyle = "rgba(18,13,9,0.55)";
    ctx.fillRect(barX, barY, barW, barH);
    var guiltW = barW * (guilt / total);
    ctx.fillStyle = GUILT;
    ctx.fillRect(barX, barY, guiltW, barH);
    ctx.fillStyle = INNOCENCE;
    ctx.fillRect(barX + guiltW, barY, barW - guiltW, barH);
    // Midline: the balance point.
    ctx.strokeStyle = PAPER;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(barX + barW / 2, barY - 3 * scale);
    ctx.lineTo(barX + barW / 2, barY + barH + 3 * scale);
    ctx.stroke();

    ctx.font = "700 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.textBaseline = "middle";
    ctx.textAlign = "left";
    ctx.fillText("GUILT " + guilt, barX + 5 * scale, barY + barH / 2);
    ctx.textAlign = "right";
    ctx.fillText(innocence + " INNOCENCE", barX + barW - 5 * scale,
      barY + barH / 2);
    ctx.restore();
  }

  function drawReveal(ctx, L, view, now, fx) {
    var age = now - fx.revealAt;
    if (age < STAMP_MS) return;
    var t = Math.min(1, (age - STAMP_MS) / 600);
    var rect = L.bench;
    var info = view.case || {};
    var suspects = info.suspects || [];
    var index = Math.max(0, suspects.indexOf(view.culprit));
    var cw = suspects.length ?
      Math.min(rect.w / suspects.length - 6, 150 * L.scale) : 100;
    var total = suspects.length * (cw + 6) - 6;
    var x0 = rect.x + (rect.w - total) / 2;
    var cx = x0 + index * (cw + 6) + cw / 2;
    var cy = rect.y + rect.h - 12 * L.scale;

    ctx.save();
    ctx.globalAlpha = 0.55 * t;
    var radius = Math.max(60, cw * 1.6);
    var gradient = ctx.createRadialGradient(cx, cy, 4, cx, cy, radius);
    gradient.addColorStop(0, rgba(AMBER, 0.55));
    gradient.addColorStop(1, "rgba(232, 163, 61, 0)");
    ctx.fillStyle = gradient;
    ctx.beginPath();
    ctx.arc(cx, cy, radius, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();

    ctx.save();
    ctx.globalAlpha = t;
    ctx.font = "700 " + Math.round(15 * L.scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    var line = ellipsize(ctx, "THE TRUTH: " + (view.culprit || "?") + " did it",
      L.width - 24);
    var lw = ctx.measureText(line).width + 24 * L.scale;
    var lh = 22 * L.scale;
    var ly = L.cards.y + lh / 2;
    ctx.fillStyle = "rgba(18, 13, 9, 0.86)";
    roundRect(ctx, L.width / 2 - lw / 2, ly - lh / 2, lw, lh, 4 * L.scale);
    ctx.fill();
    ctx.strokeStyle = rgba(AMBER, 0.7);
    ctx.lineWidth = 1.5;
    ctx.stroke();
    ctx.fillStyle = AMBER;
    ctx.fillText(line, L.width / 2, ly);
    ctx.restore();
  }

  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = String(text || "").toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = String(text || "").split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  function drawBubble(ctx, x, bottom, text, maxW, scale, alpha) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(10.5 * scale) +
      "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
    var pad = 6 * scale;
    var lineH = 13 * scale;
    var lines = wrapLines(ctx, text, Math.max(40, maxW - pad * 2), 3);
    var bw = 0;
    lines.forEach(function (l) { bw = Math.max(bw, ctx.measureText(l).width); });
    bw += pad * 2;
    var bh = lines.length * lineH + pad * 2 - 2;
    var y = bottom - bh - 6 * scale;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 5;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x - bw / 2, y, bw, bh, 5 * scale);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.beginPath();
    ctx.moveTo(x - 5 * scale, y + bh);
    ctx.lineTo(x, y + bh + 6 * scale);
    ctx.lineTo(x + 5 * scale, y + bh);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (l, i) {
      ctx.fillText(l, x - bw / 2 + pad, y + pad + i * lineH);
    });
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous cog names ("Sprocket", "Gizmo"); the
  // payload carries the policy names separately, spectator-side only. A name
  // map swaps them in wherever a name is RENDERED while the underlying events
  // keep the aliases. Baseline fillers keep their alias. Suspect names are a
  // third namespace, disjoint from the cog names, so a suspect is never
  // rewritten.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return String(text).replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function cardIndex(state) {
    var byId = {};
    ((state && state.record) || []).forEach(function (entry) {
      byId[entry.id] = entry;
    });
    return byId;
  }

  function describeCard(id, cards) {
    var card = cards[id];
    if (!card) return id;
    return id + " — " + card.kind + ", strength " + card.strength +
      ", points to " + (card.points === "guilt" ? "GUILT" : "INNOCENCE");
  }

  function countVotes(votes, value) {
    return (votes || []).filter(function (v) { return v === value; }).length;
  }

  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "The court is seated.";
      case "round":
        return event.text === "closing" ?
          "Closing round — the last word before the ballot." :
          "The bench opens round " + ((event.round || 0) + 1) + ".";
      case "argue":
        return name(event.seat) + " (" + SIDE_TAGS[event.role === 1 ? 1 : 0] +
          ") argues: “" + nameMap.text(event.text || "") + "”";
      case "whisper":
        return name(event.seat) + " whispers: “" +
          nameMap.text(event.text || "") + "”" +
          (event.lean ? " (leaning " + event.lean.replace("_", " ") + ")" : "");
      case "vote":
        return name(event.seat) + " votes " + verdictWord(event.vote) +
          (event.text ? " — “" + event.text + "”" : "");
      case "verdict":
        return "VERDICT: " + verdictWord(event.verdict) + ", " +
          countVotes(event.votes, "guilty") + "–" +
          countVotes(event.votes, "not_guilty");
      case "end":
        return event.text === "deadline" ?
          "Episode deadline — the bench called the ballot early." :
          "The court rises.";
      default: return JSON.stringify(event);
    }
  }

  function blockHead(block, rounds) {
    if (block < 0) return "THE CASE";
    if (rounds && block >= rounds) return "SEALED BALLOT";
    return "ROUND " + (block + 1);
  }

  // Renders the full transcript grouped into one section per round.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex, info) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var cards = (info && info.cards) || {};
    var rounds = info && info.rounds;
    var html = "";
    var lastBlock = null;
    var ctx = {};
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : (event.round || 0);
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block, rounds) +
          "</div>";
        lastBlock = block;
      }
      var future = i >= limit ? " feed-future" : "";
      var seatClass = typeof event.seat === "number" && event.seat >= 0 ?
        " seat" + (event.seat % COLORS.length) : "";
      // Introduced cards get their own line each: what the jury just saw.
      if (event.kind === "argue" && (event.cards || []).length) {
        event.cards.forEach(function (id) {
          html += '<div class="feed-line feed-say' + seatClass + future +
            '">' + escapeHtml(clampName(nameMap.seat(event.seat)) + " (" +
              SIDE_TAGS[event.role === 1 ? 1 : 0] + ") introduces " +
              describeCard(id, cards)) + "</div>";
        });
      }
      var cls = "feed-line feed-" + event.kind + seatClass +
        (event.kind === "whisper" ? " feed-notes" : "") +
        (event.kind === "verdict" || event.kind === "end" ? " feed-rwin" : "") +
        future;
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap, ctx)) + "</div>";
      if (event.kind === "verdict") {
        var jury = 0;
        (event.votes || []).forEach(function (v) {
          if (v === event.truth) jury += 1;
        });
        html += '<div class="feed-line feed-rwin' + future + '">' +
          escapeHtml("THE TRUTH: " + (event.text || "") + " — jury " + jury +
            "/" + (event.votes || []).length) + "</div>";
      }
      // Notes: dim, only when the seat's notes changed.
      if (event.notes && event.notes !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.notes;
        html += '<div class="feed-line feed-notes' + future + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.notes)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when each card was introduced (it flips), when each seat last argued or
  // whispered (the bubble pops), and when the verdict was read (the
  // envelopes, the stamp and the spotlight).
  function makeEffects() {
    var seen = 0;
    var blank = function () { return [null, null, null, null, null]; };
    var blankText = function () { return ["", "", "", "", ""]; };
    var argueAt = blank();
    var whisperAt = blank();
    var lastArgument = blankText();
    var lastWhisper = blankText();
    var cardAt = {};
    var revealAt = null;
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "round") {
            argueAt = blank();
            whisperAt = blank();
            lastArgument = blankText();
            lastWhisper = blankText();
          } else if (event.kind === "argue") {
            argueAt[event.seat] = animate ? now : null;
            lastArgument[event.seat] = event.text || "";
            (event.cards || []).forEach(function (id) {
              cardAt[id] = animate ? now : now - SLIDE_MS;
            });
          } else if (event.kind === "whisper") {
            whisperAt[event.seat] = animate ? now : null;
            lastWhisper[event.seat] = event.text || "";
          } else if (event.kind === "verdict") {
            revealAt = revealAt || (animate ? now : now - SPOTLIGHT_MS);
          }
        }
      },
      // The verdict frame reveals before its event is drawn in the feed; the
      // reveal animation is keyed off the STATE so the two never disagree.
      observe: function (state) {
        if (state && state.verdict && !revealAt) revealAt = Date.now();
        if (state && !state.verdict) revealAt = null;
      },
      reset: function () {
        seen = 0;
        argueAt = blank();
        whisperAt = blank();
        lastArgument = blankText();
        lastWhisper = blankText();
        cardAt = {};
        revealAt = null;
      },
      view: function () {
        return { effects: { argueAt: argueAt.slice(),
          whisperAt: whisperAt.slice(), lastArgument: lastArgument.slice(),
          lastWhisper: lastWhisper.slice(), cardAt: cardAt,
          revealAt: revealAt } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function juryTruth(state) {
    var votes = state.votes || [];
    var truth = state.truth;
    var right = 0;
    votes.forEach(function (v) { if (v && v === truth) right += 1; });
    return right;
  }

  function matchHeader(state, config) {
    if (!state) return "";
    var total = state.rounds || (config && config.rounds) || 0;
    if (state.gameDone && state.verdict) {
      return "TRUTH — " + verdictWord(state.truth) + " · JURY " +
        juryTruth(state) + "/3";
    }
    if (state.verdict) {
      return "VERDICT — " + verdictWord(state.verdict) + " " +
        countVotes(state.votes, "guilty") + "–" +
        countVotes(state.votes, "not_guilty");
    }
    if (state.phase === "ballot") return "SEALED BALLOT";
    return "ROUND " + ((state.round || 0) + 1) + (total ? " / " + total : "");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      var isJuror = seat.roleId === 2;
      var extra = isJuror ?
        (seat.vote ? '<span class="plate-backlog">' +
          escapeHtml(verdictWord(seat.vote)) + "</span>" : "") :
        '<span class="plate-backlog">' + (seat.introduced || 0) + "/" +
          (seat.handCount || 0) + " shown</span>";
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' + escapeHtml(score1(seat.score)) +
        "</span>" +
        '<span class="plate-label">' +
        escapeHtml(ROLE_TAGS[seat.roleId] || seat.role || "") + "</span>" +
        extra +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline — the bench called the ballot early";
      default: return "";
    }
  }

  // Final standings overlay: who carried the room, then a row per seat.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var roles = results.roles || [];
    var votes = results.votes || [];
    var truth = results.truth;
    var winner = -1;
    roles.forEach(function (role, i) {
      if (role === "Juror") return;
      if ((scores[i] || 0) > 0) winner = i;
    });
    var verdict = winner >= 0 ?
      escapeHtml(names[winner]) + " CARRIED THE ROOM" :
      verdictWord(results.verdict) || "NO VERDICT";
    var right = 0;
    votes.forEach(function (v) { if (v && v === truth) right += 1; });
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">VERDICT ' +
      escapeHtml(verdictWord(results.verdict)) + " · TRUTH " +
      escapeHtml(verdictWord(truth)) + " · " + (results.rounds || 0) +
      " ROUNDS</div>" +
      '<div class="end-verdict ' + (winner >= 0 ? seatColor(winner) : "") +
      '">' + verdict + "</div>" +
      '<div class="end-reason">' + escapeHtml("Jury truth " + right + "/3" +
        (reason ? " · " + reason : "")) + "</div>" +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">role</span>' +
      '<span class="end-head">vote</span>' +
      '<span class="end-head">truth</span>' +
      '<span class="end-head">score</span>';
    names.forEach(function (_, i) {
      var isJuror = roles[i] === "Juror";
      var leader = i === winner || (isJuror && votes[i] === truth);
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (i + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i] || "") +
        "</span>" +
        cell(escapeHtml(roles[i] || "")) +
        cell(escapeHtml(verdictWord(votes[i]) || "–")) +
        cell(isJuror ? (votes[i] === truth ? "✓" : "✗") : "–") +
        cell(escapeHtml(score1(scores[i])));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    effects.observe(state);
    var view = effects.view();
    view.case = state.case || {};
    view.seats = applyNames(state.seats, nameMap);
    view.roleSeat = state.roleSeat || {};
    view.record = state.record || [];
    view.transcript = state.transcript || [];
    view.whispers = state.whispers || [];
    view.tally = state.tally || {};
    view.round = state.round || 0;
    view.rounds = state.rounds || 0;
    view.phase = state.phase || "";
    view.votes = state.votes || [];
    view.sealed = state.sealed !== false;
    view.verdict = state.verdict || "";
    view.truth = state.truth || "";
    view.culprit = state.culprit || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted player frame (no `seats`) becomes a five-seat state with the
  // own seat filled in so the same scene draws.
  function playerFrameToState(data) {
    if (data.seats) return data;
    var seats = [];
    for (var i = 0; i < 5; i++) {
      seats.push({ name: "Seat " + (i + 1), role: "", roleId: -1,
        juryIndex: -1, score: 0, handCount: 0, held: 0, introduced: 0 });
    }
    var disclosure = data.disclosure || {};
    var slot = typeof data.slot === "number" ? data.slot : 0;
    seats[slot] = {
      name: data.name, role: data.role, roleId: data.roleId,
      juryIndex: data.juryIndex, score: 0,
      handCount: (data.hand || []).length,
      held: (data.hand || []).filter(function (c) {
        return c.introducedRound < 0;
      }).length,
      introduced: (data.hand || []).filter(function (c) {
        return c.introducedRound >= 0;
      }).length,
      argument: "", whisper: "", lean: "", vote: null, notes: "",
      pending: !data.done, scripted: false
    };
    var roleSeat = { prosecutor: 0, defender: 1, jurors: [2, 3, 4] };
    if (data.roleId === 0) roleSeat.prosecutor = slot;
    else if (data.roleId === 1) roleSeat.defender = slot;
    var tally = { guilt: 0, innocence: 0, guiltCards: 0, innocenceCards: 0 };
    (data.record || []).forEach(function (entry) {
      if (entry.points === "guilt") {
        tally.guilt += entry.strength; tally.guiltCards += 1;
      } else {
        tally.innocence += entry.strength; tally.innocenceCards += 1;
      }
    });
    void disclosure;
    return {
      case: data.case, seats: seats, roleSeat: roleSeat,
      record: data.record || [], transcript: data.transcript || [],
      whispers: [], tally: tally, round: data.round, rounds: data.rounds,
      phase: data.phase, votes: [null, null, null], sealed: true,
      verdict: "", truth: "", culprit: "", gameDone: data.done,
      reason: data.reason, events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen, assetBase,
    //           wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined, { cards: cardIndex(latest),
                    rounds: latest.rounds });
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per round, a marker
  // per decision (coloured by the seat) and the verdict (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : (event.round || 0);
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "argue" && kind !== "whisper" && kind !== "vote" &&
          kind !== "verdict") {
        return;
      }
      var marker = document.createElement("div");
      marker.className = "beat-marker" +
        (typeof event.seat === "number" && event.seat >= 0 ?
          " seat" + (event.seat % COLORS.length) : "") +
        (kind === "verdict" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var cards = cardIndex(states.length ? states[states.length - 1] : null);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", round: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) {
          renderFeed(options.feed, events, nameMap, index,
            { cards: cards, rounds: config.rounds });
        }
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), config);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at: an argument gets
        // read, a whisper less, the verdict longest.
        var shown = index > 0 ? events[index - 1] : null;
        var kind = shown && shown.kind;
        var stepMs = kind === "argue" ? 1600 :
          kind === "whisper" ? 900 :
          kind === "vote" ? 800 :
          kind === "verdict" ? 2600 :
          kind === "round" ? 900 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.TribunalRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
