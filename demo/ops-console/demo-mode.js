/* Monkeybot — REAL teachable agent, in-browser, driving the HubSpot-style CRM "Create deal" form.
 *
 * Not scripted: each turn it OBSERVES the live DOM, asks Claude (via the deployed
 * Cloudflare Worker /chat) for ONE structured JSON action, and EXECUTES it, then
 * re-observes — the same observe-act-verify loop the Swift Monkeybot runs through cua.
 * Steerable: type any task. Coachable: give a correction mid-run and it adapts.
 * Visuals: Clicky-style triangle pointer + Monkeybot's dialogue in a bubble AT the cursor.
 *
 * FORM-GENERIC: it never hardcodes field names. observe() auto-discovers every
 * labelled field in the active view, so the CRM form can be redesigned freely.
 */
(function () {
  // Bare mode: skip the in-page agent/cursor/bar entirely so an EXTERNAL driver
  // (the local cua agent) can operate a clean CRM with its own on-screen cursor.
  if (/[?&]bare=1/.test(location.search)) return;
  const WORKER = "https://clicky-proxy.byalikhani.workers.dev/chat";
  const MODEL = "claude-sonnet-4-6";
  const MAX_STEPS = 16;
  const $ = (s) => document.querySelector(s);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ---------- overlay: triangle pointer + dialogue bubble + control bar ----------
  const css = `
  #mb-cursor{position:fixed;z-index:10000;left:-200px;top:-200px;pointer-events:none;
    transition:left .6s cubic-bezier(.22,.7,.2,1),top .6s cubic-bezier(.22,.7,.2,1);filter:drop-shadow(0 4px 8px rgba(0,0,0,.45))}
  #mb-cursor.click #mb-tri{animation:mbclick .28s ease}
  @keyframes mbclick{0%{transform:scale(1)}45%{transform:scale(.8)}100%{transform:scale(1)}}
  #mb-bubble{position:fixed;z-index:10001;max-width:300px;padding:10px 14px;border-radius:14px;border-bottom-left-radius:4px;
    background:#6e8bff;color:#fff;font:600 13.5px/1.4 -apple-system,BlinkMacSystemFont,"Inter",sans-serif;
    box-shadow:0 14px 34px -8px rgba(110,139,255,.7),0 0 0 4px rgba(110,139,255,.18);
    opacity:0;transform:translateY(6px) scale(.96);transform-origin:bottom left;
    transition:opacity .22s,transform .22s,left .6s cubic-bezier(.22,.7,.2,1),top .6s cubic-bezier(.22,.7,.2,1);pointer-events:none}
  #mb-bubble.show{opacity:1;transform:translateY(0) scale(1)}
  #mb-bubble.coach{background:#0e1116;border:1px solid #2dd4bf;box-shadow:0 14px 34px -8px rgba(45,212,191,.5)}
  #mb-bubble .lead{display:block;font-size:11px;font-weight:800;letter-spacing:.4px;text-transform:uppercase;opacity:.8;margin-bottom:3px}
  /* Clicky form factor: a quiet notch at top-center that drops a clean panel on hover */
  #mb-dock{position:fixed;z-index:10002;top:0;left:50%;transform:translateX(-50%);
    display:flex;flex-direction:column;align-items:center;
    font-family:-apple-system,BlinkMacSystemFont,"Inter","Segoe UI",sans-serif}
  #mb-notch{display:flex;align-items:center;gap:8px;height:28px;padding:0 13px;
    background:#0b0d11;color:#e9edf5;border:1px solid #1b212b;border-top:none;
    border-radius:0 0 12px 12px;box-shadow:0 6px 18px -8px rgba(0,0,0,.6)}
  #mb-notch .mk{width:14px;height:14px;display:block}
  #mb-notch .nm{font-size:12px;font-weight:600;letter-spacing:-.1px}
  #mb-notch .st{width:6px;height:6px;border-radius:50%;background:#39414f;transition:background .2s,box-shadow .2s}
  #mb-dock.busy #mb-notch .st{background:#6e8bff;box-shadow:0 0 8px #6e8bff}
  #mb-dock.listening #mb-notch .st{background:#f87171;box-shadow:0 0 8px #f87171}
  #mb-panel{width:380px;max-width:92vw;margin-top:7px;background:#0e1116;border:1px solid #1b212b;
    border-radius:14px;box-shadow:0 30px 70px -18px rgba(0,0,0,.8);overflow:hidden;
    opacity:0;transform:translateY(-10px) scale(.985);transform-origin:top center;pointer-events:none;max-height:0;
    transition:opacity .2s ease,transform .22s cubic-bezier(.2,.7,.2,1),max-height .22s ease}
  #mb-dock.open #mb-panel{opacity:1;transform:none;pointer-events:auto;max-height:360px}
  #mb-panel .ph{display:flex;align-items:center;gap:8px;padding:12px 16px;border-bottom:1px solid #171c25}
  #mb-panel .ph .nm{font-size:13px;font-weight:600;color:#e9edf5}
  #mb-panel .ph .status{margin-left:auto;font-size:11.5px;color:#7a8699}
  #mb-panel .pbody{padding:13px 16px 15px;display:flex;flex-direction:column;gap:9px}
  #mb-panel .lbl{font-size:10px;font-weight:700;letter-spacing:.5px;text-transform:uppercase;color:#69748a}
  #mb-panel input{width:100%;background:#161b24;border:1px solid #232b38;color:#eef1f6;border-radius:9px;
    padding:9px 11px;font:13.5px -apple-system,sans-serif;outline:none;transition:border-color .15s,box-shadow .15s}
  #mb-panel input:focus{border-color:#6e8bff;box-shadow:0 0 0 3px rgba(110,139,255,.2)}
  #mb-panel input::placeholder{color:#5b6678}
  #mb-panel .rowbtns{display:flex;gap:8px;margin-top:1px}
  #mb-panel button{border:none;border-radius:9px;padding:9px 14px;font:600 13px -apple-system,sans-serif;cursor:pointer;transition:background .12s,filter .12s}
  #mb-run{flex:1;background:#6e8bff;color:#fff}#mb-run:hover{background:#5a79f5}#mb-run:disabled{opacity:.5;cursor:default}
  #mb-mic{background:#161b24;color:#aab8ff;border:1px solid #232b38}
  #mb-mic.on{background:#f87171;color:#fff;animation:micpulse 1s ease infinite}
  #mb-coach{width:100%;background:#161b24;color:#7fe7d6;border:1px solid #1f3b3a}#mb-coach:hover{filter:brightness(1.1)}
  #mb-panel .divider{height:1px;background:#171c25;margin:3px 0 1px}
  @keyframes micpulse{0%,100%{box-shadow:0 0 0 0 rgba(248,113,113,.5)}50%{box-shadow:0 0 0 6px rgba(248,113,113,0)}}
  .mb-focus{box-shadow:0 0 0 3px rgba(110,139,255,.5)!important;border-color:#6e8bff!important;transition:box-shadow .15s}
  `;
  const st = document.createElement("style"); st.textContent = css; document.head.appendChild(st);

  // triangle pointer (Clicky-style arrow)
  const cursor = document.createElement("div"); cursor.id = "mb-cursor";
  cursor.innerHTML = '<svg id="mb-tri" width="26" height="32" viewBox="0 0 26 32"><path d="M2 1.5 L2 24 L8.4 18 L13 29 L17 27.3 L12.4 16.3 L21 16.3 Z" fill="#6e8bff" stroke="#ffffff" stroke-width="1.6" stroke-linejoin="round"/></svg>';
  document.body.appendChild(cursor);
  const bubble = document.createElement("div"); bubble.id = "mb-bubble"; document.body.appendChild(bubble);

  const MK = '<svg class="mk" width="14" height="14" viewBox="0 0 26 32"><path d="M2 1.5 L2 24 L8.4 18 L13 29 L17 27.3 L12.4 16.3 L21 16.3 Z" fill="#6e8bff" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>';
  const dock = document.createElement("div"); dock.id = "mb-dock";
  dock.innerHTML = `
    <div id="mb-notch">${MK}<span class="nm">Monkeybot</span><span class="st"></span></div>
    <div id="mb-panel">
      <div class="ph">${MK}<span class="nm">Monkeybot</span><span class="status" id="mb-status">Idle</span></div>
      <div class="pbody">
        <div class="lbl">Task</div>
        <input id="mb-task" placeholder="Tell Monkeybot what to do…" value="Create a deal: Acme Corp annual renewal, $48,000, owner Sam Chen, stage Qualified to buy, close 09/30/2026, type Renewal.">
        <div class="rowbtns"><button id="mb-run">Run</button><button id="mb-mic" title="Hold to talk — or hold Ctrl+Option">Hold to talk</button></div>
        <div class="divider"></div>
        <div class="lbl">Coach — plain English</div>
        <input id="mb-coachin" placeholder="e.g. renewals are always High priority + add a follow-up task">
        <button id="mb-coach">Teach</button>
      </div>
    </div>`;
  document.body.appendChild(dock);

  // Clicky dropdown behavior: drop the panel on hover/focus; collapse when idle + unfocused.
  let dockHover = false, dockFocus = false, listening = false;
  function syncDock() {
    const el = document.getElementById("mb-dock"); if (!el) return;
    const open = dockHover || dockFocus || running || listening;
    el.classList.toggle("open", open);
    el.classList.toggle("busy", !!running);
    el.classList.toggle("listening", listening);
    // drive the dropdown via inline styles (robust against CSS descendant-rule quirks)
    const p = document.getElementById("mb-panel");
    if (p) {
      p.style.maxHeight = open ? "360px" : "0px";
      p.style.opacity = open ? "1" : "0";
      p.style.transform = open ? "none" : "translateY(-10px) scale(.985)";
      p.style.pointerEvents = open ? "auto" : "none";
    }
    const s = document.getElementById("mb-status");
    if (s) s.textContent = running ? "Running…" : (listening ? "Listening…" : "Idle");
  }
  syncDock();
  dock.addEventListener("mouseenter", () => { dockHover = true; syncDock(); });
  dock.addEventListener("mouseleave", () => { dockHover = false; syncDock(); });
  ["mb-task", "mb-coachin"].forEach((id) => {
    const e = document.getElementById(id);
    e.addEventListener("focus", () => { dockFocus = true; syncDock(); });
    e.addEventListener("blur", () => { dockFocus = false; setTimeout(syncDock, 150); });
  });

  let cursorX = -200, cursorY = -200, running = false;
  const coaching = [];

  function moveCursor(el, opts = {}) {
    const r = el.getBoundingClientRect();
    cursorX = r.left + Math.min(r.width / 2, 70) + (opts.dx || 0);
    cursorY = r.top + r.height / 2 + (opts.dy || 0);
    cursor.style.left = cursorX + "px"; cursor.style.top = cursorY + "px";
    placeBubble();
  }
  function placeBubble() {
    // bubble sits up-and-right of the pointer tip
    let bx = cursorX + 22, by = cursorY - 14;
    const bw = bubble.offsetWidth || 240;
    if (bx + bw > window.innerWidth - 12) bx = cursorX - bw - 14;
    if (by < 8) by = cursorY + 26;
    bubble.style.left = bx + "px"; bubble.style.top = by + "px";
  }
  function say(text, coach = false) {
    bubble.className = coach ? "coach" : "";
    bubble.innerHTML = `<span class="lead">${coach ? "You — coaching" : "Monkeybot"}</span>${text}`;
    bubble.classList.add("show"); placeBubble();
  }
  async function clickPulse() { cursor.classList.add("click"); await sleep(280); cursor.classList.remove("click"); }
  function focusRing(el) { el.classList.add("mb-focus"); setTimeout(() => el.classList.remove("mb-focus"), 700); }

  // ---------- field discovery (form-generic) ----------
  // Find the human-readable label for a field, preferring <label for=id>.
  function labelFor(el) {
    if (el.id) {
      const lab = document.querySelector(`label[for="${el.id}"]`);
      if (lab) return lab.textContent.trim();
    }
    const wrap = el.closest("label");
    if (wrap) return wrap.textContent.trim();
    return el.getAttribute("aria-label") || el.getAttribute("placeholder") || el.name || el.id;
  }

  // Is the field below the visible fold of the #main scroll container?
  function isBelowFold(el) {
    const main = $("#main");
    const r = el.getBoundingClientRect();
    const limit = main ? main.getBoundingClientRect().bottom : window.innerHeight;
    return r.top > limit;
  }

  // A field is a "/" slash-command field if its id is "f-stage" or it has data-slash.
  function isSlashField(el) {
    return el.id === "f-stage" || el.hasAttribute("data-slash");
  }

  // Enumerate every labelled, identifiable field currently in the form.
  function discoverFields() {
    const selector = 'input[type="text"], input[type="email"], input[type="number"], input[type="search"], input[type="tel"], input[type="url"], input:not([type]), textarea, select, input[type="checkbox"]';
    const nodes = Array.from(document.querySelectorAll(selector)).filter((el) => {
      if (!el.id) return false;                 // need an id to act on
      if (el.closest("#mb-bar")) return false;  // skip our own control bar
      if (el.offsetParent === null && el.type !== "hidden") return false; // skip hidden/inactive views
      return true;
    });
    return nodes.map((el) => {
      const isCheckbox = el.tagName === "INPUT" && el.type === "checkbox";
      const isSelect = el.tagName === "SELECT";
      const field = {
        id: el.id,
        label: labelFor(el),
        kind: isCheckbox ? "checkbox" : isSelect ? "select" : isSlashField(el) ? "slash" : "text",
        belowFold: isBelowFold(el),
      };
      if (isCheckbox) {
        field.value = el.checked ? "checked" : "unchecked";
      } else if (isSelect) {
        field.value = el.value || "(none selected)";
        field.options = Array.from(el.options).map((o) => o.value).filter(Boolean);
      } else {
        field.value = el.value || "(empty)";
      }
      if (isSlashField(el)) {
        // surface the available slash levels so the model knows what to pick
        const levels = Array.from(document.querySelectorAll("#slashmenu .opt"))
          .map((o) => o.dataset.val).filter(Boolean);
        if (levels.length) field.levels = levels;
      }
      return field;
    });
  }

  // ---------- observe the live DOM ----------
  function observe() {
    const view = $(".nav button.active")?.dataset.view || "(unknown)";
    const main = $("#main");
    const scrolled = main && main.scrollTop > 40 ? "scrolled down" : "at top";
    const recordCount = $("#queue-count")?.textContent?.trim() || "0";
    const fields = discoverFields();

    const lines = fields.map((f) => {
      let line = `- id="${f.id}" [${f.kind}] ${f.label}: ${f.value}`;
      if (f.kind === "select" && f.options) line += ` (options: ${f.options.join(", ")})`;
      if (f.kind === "slash") {
        line += ` — this is a / slash-command field; set it with slash_field`;
        if (f.levels) line += ` (levels: ${f.levels.join(", ")})`;
      }
      if (f.belowFold) line += `  [BELOW THE FOLD — scroll to bottom first]`;
      return line;
    });

    return `ACTIVE VIEW: ${view}
SCROLL: ${scrolled}
RECORD COUNT (#queue-count): ${recordCount}
FIELDS IN THIS VIEW (${fields.length}):
${lines.length ? lines.join("\n") : "(no editable fields found)"}`;
  }

  const SYSTEM = `You are Monkeybot, a teachable agent operating an internal web console. You act by emitting EXACTLY ONE JSON object per turn and NOTHING else (no prose, no code fences).

The form is not fixed — read the OBSERVATION each turn to learn which fields exist, their ids, kinds, current values, and whether each is below the fold. Never assume an id that is not listed.

Schema (pick one "action"):
{"action":"set_field","id":"<field id>","value":"...","say":"..."}        // a [text] field
{"action":"select_field","id":"<field id>","value":"<one of its options>","say":"..."}  // a [select] field
{"action":"slash_field","id":"f-stage","level":"<one of its levels>","say":"..."}       // a [slash] field
{"action":"toggle","id":"<field id>","say":"..."}                          // a [checkbox] field
{"action":"scroll","to":"bottom|top","say":"..."}
{"action":"submit","say":"..."}
{"action":"navigate","view":"<view name>","say":"..."}
{"action":"done","summary":"...","say":"..."}

Rules:
- Use the exact id from the OBSERVATION for the field you intend to change, and the matching action for its kind.
- Any field marked BELOW THE FOLD cannot be set until you scroll to "bottom".
- Don't re-set a field that already holds the correct value.
- Once the task's fields are filled, "submit", then "done".
- Every action MUST include a short, first-person "say": terse and plainspoken, like a competent operator narrating. No filler ("Let me", "I'll go ahead and"), no exclamation marks, no emoji.`;

  function buildUser(task) {
    let s = `TASK: ${task}\n\nOBSERVATION:\n${observe()}`;
    if (coaching.length) s += `\n\nCOACHING (the human taught you this — follow it exactly):\n- ${coaching.join("\n- ")}`;
    s += `\n\nReply with ONE JSON action.`;
    return s;
  }

  async function decide(task) {
    const res = await fetch(WORKER, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: MODEL, max_tokens: 400, system: SYSTEM, messages: [{ role: "user", content: buildUser(task) }] }),
    });
    if (!res.ok) throw new Error("worker " + res.status + ": " + (await res.text()).slice(0, 140));
    const data = await res.json();
    const text = (data.content || []).map(b => b.text || "").join("").trim();
    const m = text.match(/\{[\s\S]*\}/);
    if (!m) throw new Error("no JSON in model reply: " + text.slice(0, 120));
    return JSON.parse(m[0]);
  }

  // ---------- execute one action against the DOM ----------
  async function execute(a) {
    if (a.say) say(a.say);
    switch (a.action) {
      case "set_field": {
        const el = $("#" + a.id); if (!el) return;
        await moveCursor(el); await sleep(450); focusRing(el); el.focus(); await clickPulse();
        el.value = ""; for (const ch of String(a.value ?? "")) { el.value += ch; el.dispatchEvent(new Event("input", { bubbles: true })); await sleep(26); }
        el.dispatchEvent(new Event("change", { bubbles: true })); break;
      }
      case "select_field": {
        const el = $("#" + a.id); if (!el) return;
        await moveCursor(el); await sleep(420); focusRing(el); await clickPulse();
        el.value = a.value; el.dispatchEvent(new Event("change", { bubbles: true })); break;
      }
      case "slash_field": {
        const f = $("#" + (a.id || "f-stage")); if (!f) return;
        await moveCursor(f); await sleep(450); focusRing(f); f.focus(); await clickPulse();
        f.value = "/"; f.dispatchEvent(new Event("input", { bubbles: true }));
        f.dispatchEvent(new KeyboardEvent("keydown", { key: "/", bubbles: true })); await sleep(600);
        const opt = document.querySelector(`#slashmenu .opt[data-val="${a.level}"]`) || document.querySelector("#slashmenu .opt");
        if (opt) { await moveCursor(opt); await sleep(420); await clickPulse(); opt.click(); } await sleep(300); break;
      }
      case "toggle": {
        const el = $("#" + a.id); if (!el) return;
        await moveCursor(el); await sleep(380); await clickPulse(); el.click(); break;
      }
      case "scroll": { $("#main")?.scrollTo({ top: a.to === "bottom" ? 2000 : 0, behavior: "smooth" }); await sleep(650); break; }
      case "submit": { const el = $("#f-submit"); if (el) { await moveCursor(el); await sleep(420); await clickPulse(); el.click(); } await sleep(800); break; }
      case "navigate": { const el = document.querySelector(`[data-view="${a.view}"]`); if (el) { await moveCursor(el); await sleep(380); await clickPulse(); el.click(); } await sleep(500); break; }
      case "done": break;
    }
  }

  // ---------- the real loop ----------
  async function run() {
    if (running) return; running = true; syncDock();
    const runBtn = $("#mb-run"); runBtn.disabled = true; runBtn.textContent = "Running…";
    const task = $("#mb-task").value.trim();
    try {
      say("Reading the form.");
      for (let step = 1; step <= MAX_STEPS; step++) {
        let action;
        try { action = await decide(task); }
        catch (e) { say(e.message); break; }
        await execute(action);
        if (action.action === "done") { say(action.summary || "Done."); break; }
        await sleep(350);
      }
    } finally { running = false; runBtn.disabled = false; runBtn.textContent = "Run"; syncDock(); }
  }
  function teach() {
    const c = $("#mb-coachin").value.trim(); if (!c) return;
    coaching.push(c); $("#mb-coachin").value = "";
    say(c, true);  // show the coaching as a bubble from "You"
  }

  // ---------- voice: push-to-talk (Web Speech API; needs HTTPS — use the pages.dev URL) ----------
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  let recog = null, recognizing = false, pttDown = false;
  function handleVoice(text) {
    text = (text || "").trim(); if (!text) return;
    if (running) { coaching.push(text); say(text, true); }   // mid-run → live coaching, adapts next turn
    else { $("#mb-task").value = text; }                       // idle → fills the task; press Run
  }
  function startPTT() {
    if (!SR || recognizing) return;
    recog = new SR(); recog.lang = "en-US"; recog.interimResults = false; recog.maxAlternatives = 1;
    recog.onresult = (e) => handleVoice(e.results[0][0].transcript);
    recog.onend = () => { recognizing = false; listening = false; $("#mb-mic")?.classList.remove("on"); syncDock(); };
    try { recog.start(); recognizing = true; listening = true; $("#mb-mic")?.classList.add("on"); syncDock(); } catch (_) {}
  }
  function stopPTT() { if (recog && recognizing) { try { recog.stop(); } catch (_) {} } }
  // Hold Ctrl+Option to talk (mirrors the Swift app's push-to-talk) …
  window.addEventListener("keydown", (e) => { if (e.ctrlKey && e.altKey && !pttDown) { pttDown = true; startPTT(); } });
  window.addEventListener("keyup", () => { if (pttDown) { pttDown = false; stopPTT(); } });
  // … or press-and-hold the "Hold to talk" button.
  const mic = $("#mb-mic");
  mic.addEventListener("mousedown", (e) => { e.preventDefault(); startPTT(); });
  mic.addEventListener("mouseup", stopPTT);
  mic.addEventListener("mouseleave", stopPTT);
  if (!SR) { mic.disabled = true; mic.textContent = "Voice n/a"; mic.title = "SpeechRecognition needs Chrome over HTTPS (the pages.dev URL)"; }

  $("#mb-run").onclick = run;
  $("#mb-coach").onclick = teach;
  $("#mb-coachin").addEventListener("keydown", e => { if (e.key === "Enter") teach(); });
  $("#mb-task").addEventListener("keydown", e => { if (e.key === "Enter") run(); });
  window.addEventListener("resize", placeBubble);
  if (/[?&]demo=1/.test(location.search)) window.addEventListener("load", () => setTimeout(run, 800));
})();
