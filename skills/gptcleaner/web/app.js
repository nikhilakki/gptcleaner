/* gptcleaner web - UI wiring + three.js ghost field */
(function () {
  "use strict";
  const $ = (id) => document.getElementById(id);
  const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ================= options ================= */

  const CHECKS = {
    invisible: "opt-invisible", spaces: "opt-spaces",
    punctuation: "opt-punctuation", dashes: "opt-dashes",
    spacing: "opt-spacing", markdown: "opt-markdown",
    stripLists: "opt-striplists", json: "opt-json",
  };

  function options() {
    const o = {};
    for (const [key, id] of Object.entries(CHECKS)) o[key] = $(id).checked;
    o.lineSpacing = $("opt-linespacing").value;
    return o;
  }

  // chip visual state
  document.querySelectorAll(".chip input").forEach((box) => {
    box.addEventListener("change", () => {
      box.closest(".chip").classList.toggle("on", box.checked);
      syncJsonMode();
      if ($("in").value) doClean(false);
    });
  });

  // json mode replaces the text passes; dim their chips so that is visible
  function syncJsonMode() {
    document.querySelector(".chips").classList.toggle("json-mode", $("opt-json").checked);
  }
  syncJsonMode();
  $("opt-linespacing").addEventListener("change", () => $("in").value && doClean(false));

  /* ================= radar (live scan) ================= */

  const fmt = (n) => n.toLocaleString("en-US");
  let radarTimer = null;

  function sweepRadar() {
    const hits = GPTCleaner.scan($("in").value);
    const pills = $("pills");
    const total = hits.reduce((a, h) => a + h.count, 0);
    $("radar-count").textContent = total ? "· " + fmt(total) + " ghost" + (total === 1 ? "" : "s") + " detected" : "";
    if (!hits.length) {
      pills.innerHTML = '<span class="none">' +
        ($("in").value ? "radar is clear. no hidden characters in there." :
         "paste something and the radar starts sweeping.") + "</span>";
      return;
    }
    pills.innerHTML = hits.slice(0, 24).map((h) =>
      '<span class="pill">' + h.code + " <b>" + esc(h.name) + '</b> <span class="n">&times;' +
      h.count + "</span></span>").join("") +
      (hits.length > 24 ? '<span class="none">+ ' + (hits.length - 24) + " more kinds</span>" : "");
  }

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  $("in").addEventListener("input", () => {
    clearTimeout(radarTimer);
    radarTimer = setTimeout(sweepRadar, 120);
  });

  /* ================= clean ================= */

  function doClean(burst) {
    const src = $("in").value;
    if (!src) { $("out").value = ""; $("score").hidden = true; return; }
    const { text, report } = GPTCleaner.clean(src, options());
    $("out").value = text;

    const bits = [];
    bits.push(fmt(report.charsIn) + " chars in -> <b>" + fmt(report.charsOut) + " out</b>");
    bits.push(report.hiddenTotal
      ? "<b>" + fmt(report.hiddenTotal) + " ghost" + (report.hiddenTotal === 1 ? "" : "s") + " banished</b>"
      : '<span class="zero">no ghosts found</span>');
    if (report.json) {
      const f = report.json.fixes;
      const done = [
        [f.backslashes, "stray backslash", "stray backslashes"],
        [f.entities, "html entity", "html entities"],
        [f.trailingCommas, "trailing comma", "trailing commas"],
        [f.fences, "code fence", "code fences"],
        [f.unescaped, "escaping layer", "escaping layers"],
      ].filter(([n]) => n).map(([n, one, many]) => "<b>" + fmt(n) + "</b> " + (n === 1 ? one : many));
      if (done.length) bits.push(done.join(", ") + " removed");
      bits.push(report.json.valid
        ? "<b>valid json</b>"
        : '<span class="bad">still invalid: ' + esc(report.json.error) + "</span>");
    } else {
      bits.push(report.punctuationTotal
        ? "<b>" + fmt(report.punctuationTotal) + "</b> smart marks straightened"
        : '<span class="zero">punctuation already straight</span>');
    }
    const score = $("score");
    score.innerHTML = bits.join(" &nbsp;|&nbsp; ");
    score.hidden = false;

    const jsonFixed = report.json
      ? Object.values(report.json.fixes).reduce((a, n) => a + n, 0) : 0;
    if (burst) ghostBurst(Math.min(report.hiddenTotal + report.punctuationTotal + jsonFixed, 42) || 8);
  }

  $("clean").addEventListener("click", () => doClean(true));
  addEventListener("keydown", (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); doClean(true); }
  });

  $("copy").addEventListener("click", async () => {
    if (!$("out").value) return;
    try { await navigator.clipboard.writeText($("out").value); } catch (e) {
      $("out").select(); document.execCommand("copy");
    }
    flash($("copy"), "copied!");
  });

  $("paste").addEventListener("click", async () => {
    try {
      $("in").value = await navigator.clipboard.readText();
      sweepRadar(); doClean(true);
    } catch (e) { $("in").focus(); flash($("paste"), "ctrl+v here"); }
  });

  function flash(btn, msg) {
    const old = btn.textContent;
    btn.textContent = msg;
    setTimeout(() => { btn.textContent = old; }, 1200);
  }

  /* haunted sample: built programmatically so this file stays clean */
  $("sample").addEventListener("click", () => {
    if ($("opt-json").checked) {
      // json pasted out of a rich-text editor: hard-break backslashes, &#x20;
      // indents, a no-break space, a zero-width space and trailing commas
      const I = "&#x20; ";
      $("in").value = "```json\n{\\\n" +
        I + '"screen": "Splash Screen",\\\n' +
        I + '"colors": ["#4AA3F4", "#1D3873",],\\\n' +
        I + '"note": "values like \\"&nbsp;\\" stay exactly as written",​\\\n' +
        "}\n```";
      sweepRadar(); doClean(true);
      return;
    }
    const ZW = "​", NB = " ", SH = "­", WJ = "⁠",
          BOM = "﻿", TAG = "\u{E0057}\u{E0054}\u{E0046}";
    $("in").value =
      BOM + "# The" + ZW + " Report\r\n\r\n\r\n" +
      "Here’s the “final” draft — it has **bold** claims," +
      NB + "an ellipsis… and a soft" + SH + "hyphen.\r\n\r\n" +
      "- first point  with   doubled spaces   \r\n" +
      "• second point – an en dash\r\n\r\n" +
      "> a quote with `code` and a [link](https://example.com)\r\n\r\n" +
      "the watermark tags hiding after this period are invisible." + TAG + WJ + "\r\n";
    sweepRadar(); doClean(true);
  });

  /* ================= three.js ghost field ================= */

  const GLYPHS = ["—", "“", "”", "’", "…", "¶",
                  "•", "¨", "*", "#", "`", "¬", "␣", "§",
                  "ZW", "⌘", "~", "·"];
  const TINTS = [
    { c: "#6b58a8", w: 12 },   // muted violet, most common
    { c: "#5cd6ff", w: 3 },    // cyan
    { c: "#ff4fa3", w: 2 },    // pink
    { c: "#c9f24b", w: 1 },    // lime, rare
  ];

  let scene, camera, renderer, sprites = [], bursts = [];
  const texCache = new Map();

  function pickTint() {
    const total = TINTS.reduce((a, t) => a + t.w, 0);
    let r = Math.random() * total;
    for (const t of TINTS) { if ((r -= t.w) <= 0) return t.c; }
    return TINTS[0].c;
  }

  function glyphTexture(glyph, color) {
    const key = glyph + color;
    if (texCache.has(key)) return texCache.get(key);
    const cv = document.createElement("canvas");
    cv.width = cv.height = 128;
    const g = cv.getContext("2d");
    g.font = "700 84px 'JetBrains Mono', monospace";
    g.textAlign = "center"; g.textBaseline = "middle";
    g.fillStyle = color;
    g.fillText(glyph, 64, 70);
    const tex = new THREE.CanvasTexture(cv);
    texCache.set(key, tex);
    return tex;
  }

  function makeGhost(glyph, color, opacity) {
    const mat = new THREE.SpriteMaterial({
      map: glyphTexture(glyph, color),
      transparent: true, opacity, depthWrite: false,
    });
    return new THREE.Sprite(mat);
  }

  function initGhosts() {
    if (typeof THREE === "undefined") return;   // cdn blocked: page still works
    const canvas = $("ghosts");
    renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true });
    renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    scene = new THREE.Scene();
    camera = new THREE.PerspectiveCamera(60, 1, 0.1, 100);
    camera.position.z = 16;

    const count = innerWidth < 700 ? 45 : 90;
    for (let i = 0; i < count; i++) {
      const s = makeGhost(
        GLYPHS[(Math.random() * GLYPHS.length) | 0],
        pickTint(), 0.12 + Math.random() * 0.3);
      const scale = 0.5 + Math.random() * 1.4;
      s.scale.set(scale, scale, 1);
      s.position.set((Math.random() - 0.5) * 44, (Math.random() - 0.5) * 26,
                     -30 + Math.random() * 26);
      s.userData = {
        vx: (Math.random() - 0.5) * 0.008,
        vy: 0.004 + Math.random() * 0.012,
        vr: (Math.random() - 0.5) * 0.004,
      };
      sprites.push(s); scene.add(s);
    }
    resize();
    addEventListener("resize", resize);

    if (reduceMotion) { renderer.render(scene, camera); return; }
    addEventListener("pointermove", (e) => {
      mouseX = (e.clientX / innerWidth - 0.5);
      mouseY = (e.clientY / innerHeight - 0.5);
    });
    requestAnimationFrame(tick);
  }

  let mouseX = 0, mouseY = 0;

  function resize() {
    if (!renderer) return;
    renderer.setSize(innerWidth, innerHeight, false);
    camera.aspect = innerWidth / innerHeight;
    camera.updateProjectionMatrix();
    if (reduceMotion) renderer.render(scene, camera);
  }

  function tick() {
    for (const s of sprites) {
      const u = s.userData;
      s.position.x += u.vx; s.position.y += u.vy;
      s.material.rotation += u.vr;
      if (s.position.y > 15) { s.position.y = -15; s.position.x = (Math.random() - 0.5) * 44; }
      if (s.position.x > 24) s.position.x = -24;
      if (s.position.x < -24) s.position.x = 24;
    }
    for (let i = bursts.length - 1; i >= 0; i--) {
      const b = bursts[i], u = b.userData;
      b.position.x += u.vx; b.position.y += u.vy;
      u.vx *= 0.985; u.vy = u.vy * 0.985 + 0.004;   // drift up as they fade
      b.material.rotation += u.vr;
      b.material.opacity -= 0.011;
      if (b.material.opacity <= 0) {
        scene.remove(b); b.material.dispose(); bursts.splice(i, 1);
      }
    }
    camera.position.x += (mouseX * 2.4 - camera.position.x) * 0.03;
    camera.position.y += (-mouseY * 1.6 - camera.position.y) * 0.03;
    camera.lookAt(0, 0, -12);
    renderer.render(scene, camera);
    requestAnimationFrame(tick);
  }

  function ghostBurst(n) {
    if (!scene || reduceMotion) return;
    for (let i = 0; i < n; i++) {
      const b = makeGhost(
        GLYPHS[(Math.random() * GLYPHS.length) | 0],
        Math.random() < 0.5 ? "#5cd6ff" : "#ff4fa3",
        0.9);
      const sc = 0.7 + Math.random() * 1.1;
      b.scale.set(sc, sc, 1);
      b.position.set((Math.random() - 0.5) * 6, (Math.random() - 0.5) * 4, -6);
      const a = Math.random() * Math.PI * 2, v = 0.12 + Math.random() * 0.22;
      b.userData = { vx: Math.cos(a) * v, vy: Math.sin(a) * v, vr: (Math.random() - 0.5) * 0.2 };
      bursts.push(b); scene.add(b);
    }
  }

  initGhosts();
})();
