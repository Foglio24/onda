// Seaglass's website: reveal on scroll and the small demos. No libraries, no requests.
(() => {
  "use strict";

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  /** Runs `start` while `element` is on screen and the tab is showing, `stop` otherwise. */
  function whileVisible(element, start, stop) {
    let on = false;
    let visible = false;
    const update = () => {
      const should = visible && !document.hidden;
      if (should && !on) { on = true; start(); } else if (!should && on) { on = false; stop(); }
    };
    if (!("IntersectionObserver" in window)) { visible = true; update(); return; }
    new IntersectionObserver((entries) => { visible = entries[entries.length - 1].isIntersecting; update(); }, { rootMargin: "80px" }).observe(element);
    document.addEventListener("visibilitychange", update);
  }

  // ---- Navigation -------------------------------------------------------------------------------
  const nav = $(".nav");
  let scrollQueued = false;
  const onScroll = () => {
    if (scrollQueued) return;
    scrollQueued = true;
    requestAnimationFrame(() => { scrollQueued = false; nav.classList.toggle("scrolled", window.scrollY > 12); });
  };
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  const burger = $("#burger");
  const links = $("#links");
  const closeMenu = () => { links.classList.remove("open"); burger.setAttribute("aria-expanded", "false"); };
  burger.addEventListener("click", () => {
    const open = links.classList.toggle("open");
    burger.setAttribute("aria-expanded", String(open));
  });
  links.addEventListener("click", (event) => { if (event.target.closest("a")) closeMenu(); });
  document.addEventListener("keydown", (event) => { if (event.key === "Escape") closeMenu(); });

  // ---- Reveal on scroll -------------------------------------------------------------------------
  const revealed = $$(".reveal");
  for (const group of $$(".grid, .stats, .langs")) {
    $$(".reveal", group).forEach((el, index) => el.style.setProperty("--d", `${Math.min(index, 8) * 70}ms`));
  }
  if (reduced.matches || !("IntersectionObserver" in window)) {
    revealed.forEach((el) => el.classList.add("in"));
  } else {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("in");
        observer.unobserve(entry.target);
      }
    }, { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });
    revealed.forEach((el) => observer.observe(el));
  }

  // ---- Hero: the art leans towards the pointer --------------------------------------------------
  const art = $("#heroArt");
  if (art && !reduced.matches && window.matchMedia("(pointer: fine)").matches) {
    let frame = 0;
    const lean = (x, y) => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => { art.style.setProperty("--px", x.toFixed(3)); art.style.setProperty("--py", y.toFixed(3)); });
    };
    document.addEventListener("pointermove", (event) => {
      lean((event.clientX / window.innerWidth - 0.5) * 2, (event.clientY / window.innerHeight - 0.5) * 2);
    }, { passive: true });
  }

  // ---- AutoMix: one song gliding into the next ----------------------------------------------
  (function autoMix() {
    const canvas = $("#mixCanvas");
    const readout = $("#mixReadout");
    if (!canvas || !canvas.getContext) return;
    const ctx = canvas.getContext("2d");
    let W = 960, H = 560, PLAY = 480;
    const BEAT_PX = 44, PX_PER_SECOND = 92;
    const BPM_A = 124, BPM_B = 128;
    const MIX_START = 4, MIX_END = 12, GLIDE_END = 10, CYCLE = 16;
    const LANE_A = { top: 44, bottom: 256 }, LANE_B = { top: 304, bottom: 516 };
    const smooth = (a, b, t) => { const x = Math.min(1, Math.max(0, (t - a) / (b - a))); return x * x * (3 - 2 * x); };
    const fract = (x) => x - Math.floor(x);
    const noise = (i) => fract(Math.sin(i * 12.9898) * 43758.5453);

    // Where each song is, in beats, 60 times a second: A's tempo glides from 124 to 128 BPM, B plays at its own.
    const STEP = 1 / 60;
    const count = Math.ceil(CYCLE / STEP) + 2;
    const posA = new Float32Array(count);
    let a = 0;
    for (let k = 0; k < count; k++) {
      posA[k] = a;
      a += (BPM_A / 60) * (1 + (BPM_B / BPM_A - 1) * smooth(MIX_START, GLIDE_END, k * STEP)) * STEP;
    }
    const beatsB = (t) => (BPM_B / 60) * (t - MIX_START);
    const alignment = fract(posA[Math.round(GLIDE_END / STEP)]) - fract(beatsB(GLIDE_END)); // B's beats land on A's
    const posB = (t) => beatsB(t) + alignment + (alignment < 0 ? 1 : 0);
    const endOfA = posA[Math.round(MIX_END / STEP)];

    /** A drum-like envelope: a hit on every beat, hats between, a swell every bar. */
    function wave(beat, seed) {
      const phase = fract(beat);
      const kick = Math.exp(-phase * 7);
      const hat = Math.exp(-fract(beat * 2 + 0.5) * 11) * 0.32;
      const swell = 0.62 + 0.24 * Math.sin(beat * 0.8 + seed);
      const grain = 0.82 + 0.18 * noise(Math.floor(beat * 8) + seed * 100);
      return Math.min(1, (0.2 + 0.7 * kick + hat) * swell * grain);
    }

    let scale = 1;
    function resize() {
      const width = canvas.getBoundingClientRect().width || 960;
      // On a narrow screen it is drawn larger and taller, so the waveforms stay readable.
      const narrow = width < 560;
      W = narrow ? 600 : 960;
      H = narrow ? 720 : 560;
      PLAY = W / 2;
      LANE_A.bottom = H / 2 - 24;
      LANE_B.top = H / 2 + 24;
      LANE_B.bottom = H - 44;
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round((width * ratio * H) / W);
      scale = canvas.width / W;
    }

    function lane(position, lanePos, color, gainAt, exists) {
      const middle = (lanePos.top + lanePos.bottom) / 2;
      const half = (lanePos.bottom - lanePos.top) / 2;
      ctx.lineWidth = 1;
      for (let x = 0; x < W; x += 6) {
        const beat = position + (x - PLAY) / BEAT_PX;
        if (!exists(beat)) continue;
        const gain = gainAt(clockAt(x));
        const height = wave(beat, color.seed) * half * (0.42 + 0.58 * gain);
        ctx.fillStyle = `rgba(${color.rgb}, ${(x < PLAY ? 0.55 : 0.95) * (0.3 + 0.7 * gain)})`;
        ctx.fillRect(x, middle - height, 3.4, height * 2);
      }
      // The beats, as lines: A's drift against B's until the tempo has glided.
      ctx.fillStyle = `rgba(${color.rgb}, 0.2)`;
      const first = Math.ceil(position - PLAY / BEAT_PX);
      for (let beat = first; beat < position + (W - PLAY) / BEAT_PX; beat++) {
        if (!exists(beat)) continue;
        ctx.fillRect(PLAY + (beat - position) * BEAT_PX - 0.5, lanePos.top, 1, lanePos.bottom - lanePos.top);
      }
    }

    let nowT = 0;
    const clockAt = (x) => nowT + (x - PLAY) / PX_PER_SECOND;

    function draw(t) {
      nowT = t;
      ctx.setTransform(scale, 0, 0, scale, 0, 0);
      ctx.clearRect(0, 0, W, H);
      const fade = Math.min(1, t / 0.5, (CYCLE - t) / 0.5);
      ctx.globalAlpha = Math.max(0, fade);

      const index = Math.min(count - 1, Math.round(t / STEP));
      const gainA = (time) => 1 - smooth(MIX_START, MIX_END, time);
      const gainB = (time) => smooth(MIX_START, MIX_END, time);

      // The mix, as a zone with the volume curves and the bass swap, as in the app's editor.
      const x0 = PLAY + (MIX_START - t) * PX_PER_SECOND;
      const x1 = PLAY + (MIX_END - t) * PX_PER_SECOND;
      const xm = (x0 + x1) / 2;
      ctx.fillStyle = "rgba(236, 63, 142, 0.1)";
      ctx.fillRect(x0, 24, x1 - x0, H - 48);
      ctx.strokeStyle = "rgba(236, 63, 142, 0.55)";
      ctx.lineWidth = 1.5;
      ctx.setLineDash([6, 6]);
      ctx.strokeRect(x0, 24, x1 - x0, H - 48);
      ctx.setLineDash([]);

      lane(posA[index], LANE_A, { rgb: "255, 138, 92", seed: 1 }, gainA, (beat) => beat <= endOfA);
      lane(posB(t), LANE_B, { rgb: "107, 140, 255", seed: 2 }, gainB, (beat) => beat >= 0);

      ctx.lineJoin = "round";
      ctx.lineCap = "round";
      ctx.lineWidth = 3.5;
      ctx.strokeStyle = "#7fb8ff";
      ctx.beginPath();
      for (let x = x0; x <= x1; x += 6) {
        const y = LANE_A.top + (1 - gainA(clockAt(x))) * (LANE_A.bottom - LANE_A.top);
        x === x0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();
      ctx.beginPath();
      for (let x = x0; x <= x1; x += 6) {
        const y = LANE_B.bottom - gainB(clockAt(x)) * (LANE_B.bottom - LANE_B.top);
        x === x0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();
      ctx.strokeStyle = "#ffcf4a";
      ctx.beginPath();
      const cutA = LANE_A.top + (LANE_A.bottom - LANE_A.top) * 0.52;
      const cutB = LANE_B.bottom - (LANE_B.bottom - LANE_B.top) * 0.52;
      ctx.moveTo(x0, LANE_A.top + 6); ctx.lineTo(xm, LANE_A.top + 6); ctx.lineTo(xm, cutA); ctx.lineTo(x1, cutA);
      ctx.moveTo(x0, LANE_B.bottom - 6); ctx.lineTo(xm, LANE_B.bottom - 6); ctx.lineTo(xm, cutB); ctx.lineTo(x1, cutB);
      ctx.stroke();

      // The playhead.
      ctx.fillStyle = "#fff";
      ctx.fillRect(PLAY - 1, 12, 2, H - 24);
      ctx.beginPath();
      ctx.moveTo(PLAY - 8, 6); ctx.lineTo(PLAY + 8, 6); ctx.lineTo(PLAY, 18); ctx.closePath();
      ctx.fill();
      ctx.globalAlpha = 1;

      // The tempo of the song you hear: A's, gliding to B's, then B's own.
      const bpm = BPM_A + (BPM_B - BPM_A) * smooth(MIX_START, GLIDE_END, t);
      const text = t >= GLIDE_END ? `${BPM_B} BPM` : t <= MIX_START ? `${BPM_A} BPM` : `${bpm.toFixed(1)} BPM`;
      if (readout.textContent !== text) readout.textContent = text;
    }

    let frame = 0;
    let startedAt = 0;
    const tick = (now) => {
      draw(((now - startedAt) / 1000) % CYCLE);
      frame = requestAnimationFrame(tick);
    };
    resize();
    draw(8);
    if ("ResizeObserver" in window) new ResizeObserver(() => { resize(); if (!frame) draw(8); }).observe(canvas);
    if (reduced.matches) return;
    whileVisible($("#mixStage"), () => { startedAt = performance.now() - 2000; frame = requestAnimationFrame(tick); }, () => { cancelAnimationFrame(frame); frame = 0; });
  })();

  // ---- Tempo fader ------------------------------------------------------------------------------
  (function tempo() {
    const range = $("#tRange");
    if (!range) return;
    const lock = $("#tLock");
    const deck = $("#deck");
    const hint = $("#tHint");
    const BASE = 124;
    const render = () => {
      const percent = Number(range.value);
      const ratio = 1 + percent / 100;
      $("#tSpeed").textContent = `${percent > 0 ? "+" : percent < 0 ? "−" : ""}${Math.abs(percent)}%`;
      $("#tBpm").textContent = (BASE * ratio).toFixed(1);
      const semitones = 12 * Math.log2(ratio);
      $("#tPitch").textContent = lock.checked || percent === 0 ? "original key" : `${semitones > 0 ? "+" : "−"}${Math.abs(semitones).toFixed(2)} st`;
      deck.style.setProperty("--spin", `${(1.8 / ratio).toFixed(3)}s`);
    };
    range.addEventListener("input", () => { hint.style.opacity = "0"; render(); });
    lock.addEventListener("change", render);
    render();
  })();

  // ---- Lyrics and karaoke -----------------------------------------------------------------------
  (function lyrics() {
    const demo = $("#lyricsDemo");
    if (!demo) return;
    const lines = $$(".lines li", demo);
    const fill = $("#vocalFill");
    const out = $("#vocalOut");
    let active = 0;
    const show = (index) => {
      active = index;
      lines.forEach((line, i) => {
        line.classList.toggle("on", i === index);
        line.classList.toggle("near", Math.abs(i - index) === 1);
      });
    };
    show(1);
    if (reduced.matches) return;
    let timer = 0;
    let frame = 0;
    let startedAt = 0;
    const vocals = (now) => {
      // From the full voice to silence and back, slowly, as a slider dragged by hand.
      const phase = ((now - startedAt) / 11000) % 1;
      const level = Math.round((0.5 + 0.5 * Math.cos(phase * Math.PI * 2)) * 100);
      fill.style.width = `${level}%`;
      out.textContent = `${level}%`;
      frame = requestAnimationFrame(vocals);
    };
    whileVisible(demo, () => {
      startedAt = performance.now();
      timer = setInterval(() => show((active + 1) % lines.length), 2300);
      frame = requestAnimationFrame(vocals);
    }, () => { clearInterval(timer); cancelAnimationFrame(frame); });
  })();

  // ---- Equaliser --------------------------------------------------------------------------------
  (function equaliser() {
    const root = $("#eq");
    if (!root) return;
    const presets = {
      flat: [0, 0, 0, 0, 0, 0],
      bass: [6, 4, 1, 0, 0, 0],
      vocal: [-2, -1, 3, 5, 3, -1],
      treble: [0, 0, 0, 1, 4, 6],
      rock: [4, 2, -2, -1, 3, 4],
      classical: [3, 2, -1, -1, 1, 3],
    };
    const columns = $$(".band-col", root);
    const buttons = $$("[data-eq]", root);
    const RANGE = 8;
    function set(name) {
      const values = presets[name] || presets.flat;
      columns.forEach((column, index) => {
        const db = values[index];
        const bar = $("i", column);
        const share = Math.abs(db) / RANGE * 50;
        bar.style.height = `max(2px, ${share}%)`;
        bar.style.top = db > 0 ? `${50 - share}%` : "50%";
        $(".db", column).textContent = db === 0 ? "0" : `${db > 0 ? "+" : "−"}${Math.abs(db)}`;
      });
      buttons.forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.eq === name)));
    }
    let touched = false;
    buttons.forEach((button) => button.addEventListener("click", () => { touched = true; set(button.dataset.eq); }));
    set("flat");
    if (reduced.matches) return;
    // Until someone tries it, it plays through the presets by itself.
    const order = ["bass", "vocal", "treble", "rock", "classical", "flat"];
    let step = 0;
    let timer = 0;
    whileVisible(root, () => {
      timer = setInterval(() => { if (!touched) set(order[step++ % order.length]); }, 2600);
      if (!touched) setTimeout(() => { if (!touched) set(order[step++ % order.length]); }, 500);
    }, () => clearInterval(timer));
  })();

  // ---- Devices: tabs ------------------------------------------------------------------------------
  (function tabs() {
    const list = $$('[role="tab"]');
    if (list.length === 0) return;
    const select = (tab, focus) => {
      for (const other of list) {
        const on = other === tab;
        other.setAttribute("aria-selected", String(on));
        other.tabIndex = on ? 0 : -1;
        $("#" + other.getAttribute("aria-controls")).hidden = !on;
      }
      if (focus) tab.focus();
    };
    list.forEach((tab, index) => {
      tab.addEventListener("click", () => select(tab, false));
      tab.addEventListener("keydown", (event) => {
        const jump = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
        if (jump) { event.preventDefault(); select(list[(index + jump + list.length) % list.length], true); }
        else if (event.key === "Home") { event.preventDefault(); select(list[0], true); }
        else if (event.key === "End") { event.preventDefault(); select(list[list.length - 1], true); }
      });
    });
  })();

  // ---- Copy the AltStore address ---------------------------------------------------------------
  (function copy() {
    const button = $("#copyAlt");
    const source = $("#altSource");
    const note = $("#copied");
    if (!button) return;
    let timer = 0;
    button.addEventListener("click", async () => {
      const text = source.textContent.trim();
      let done = false;
      try { await navigator.clipboard.writeText(text); done = true; } catch { /* try the old way */ }
      if (!done) {
        try {
          const range = document.createRange();
          range.selectNodeContents(source);
          const selection = getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          done = document.execCommand("copy");
        } catch { /* the address stays selected for a manual copy */ }
      }
      if (!done) return;
      note.textContent = "Copied";
      clearTimeout(timer);
      timer = setTimeout(() => { note.textContent = ""; }, 2600);
    });
  })();
})();
