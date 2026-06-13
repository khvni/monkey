/* Monkeybot teachable-agent demo driver (self-contained, no deps).
 * Trigger: load index.html?demo=1  OR click the floating "Run Monkeybot demo" button.
 * Narrative: the agent tries once and fumbles -> you coach it -> it repeats the
 * rote incident-logging workflow PERFECTLY, fast, several times. ~55s.
 * It drives the SAME real form handlers the app already exposes (faithful to what
 * cua does live), just paced + narrated for a recordable demo. */
(function () {
  const $ = (s) => document.querySelector(s);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // ---- inject cursor + coach UI ----
  const css = `
  #mb-cursor{position:fixed;z-index:9999;left:-100px;top:-100px;display:flex;align-items:center;gap:8px;
    padding:6px 12px 6px 8px;border-radius:24px;background:#6e8bff;color:#fff;font:600 13px/1 -apple-system,sans-serif;
    box-shadow:0 10px 30px -6px rgba(110,139,255,.7),0 0 0 4px rgba(110,139,255,.22);pointer-events:none;
    transition:left .62s cubic-bezier(.22,.7,.2,1),top .62s cubic-bezier(.22,.7,.2,1);transform:translate(-6px,-6px)}
  #mb-cursor .pt{font-size:16px;filter:drop-shadow(0 1px 1px rgba(0,0,0,.3))}
  #mb-cursor.click{animation:mbclick .3s ease}
  @keyframes mbclick{0%{transform:translate(-6px,-6px) scale(1)}50%{transform:translate(-6px,-6px) scale(.82)}100%{transform:translate(-6px,-6px) scale(1)}}
  #mb-coach{position:fixed;z-index:9998;top:18px;left:50%;transform:translateX(-50%) translateY(-14px);
    max-width:720px;display:flex;align-items:center;gap:12px;padding:13px 20px;border-radius:14px;
    background:rgba(16,19,26,.92);backdrop-filter:blur(16px);border:1px solid #2c3644;color:#eef1f6;
    font:500 14.5px/1.4 -apple-system,sans-serif;box-shadow:0 24px 60px -12px rgba(0,0,0,.7);
    opacity:0;transition:opacity .3s,transform .3s}
  #mb-coach.show{opacity:1;transform:translateX(-50%) translateY(0)}
  #mb-coach .who{font-weight:700;padding:3px 9px;border-radius:8px;font-size:12px;flex-shrink:0}
  #mb-coach .who.bot{background:rgba(110,139,255,.2);color:#aab8ff}
  #mb-coach .who.you{background:rgba(45,212,191,.18);color:#5eead4}
  #mb-coach .who.ok{background:rgba(52,211,153,.18);color:#6ee7b7}
  #mb-coach .who.bad{background:rgba(255,107,107,.18);color:#ff9b9b}
  #mb-start{position:fixed;z-index:9997;right:22px;bottom:22px;padding:12px 18px;border:none;border-radius:12px;
    background:linear-gradient(145deg,#6e8bff,#8a6bff);color:#fff;font:600 14px -apple-system,sans-serif;cursor:pointer;
    box-shadow:0 12px 30px -8px rgba(110,139,255,.7)}
  #mb-start:hover{filter:brightness(1.08)}
  .mb-focus{box-shadow:0 0 0 3px rgba(110,139,255,.45)!important;border-color:#6e8bff!important}
  `;
  const style = document.createElement("style"); style.textContent = css; document.head.appendChild(style);

  const cursor = document.createElement("div");
  cursor.id = "mb-cursor"; cursor.innerHTML = '<span class="pt">🐵</span><span>Monkeybot</span>';
  document.body.appendChild(cursor);
  const coach = document.createElement("div"); coach.id = "mb-coach"; document.body.appendChild(coach);

  function say(who, cls, text) {
    coach.innerHTML = `<span class="who ${cls}">${who}</span><span>${text}</span>`;
    coach.classList.add("show");
  }
  async function moveTo(sel) {
    const el = $(sel); if (!el) return null;
    el.scrollIntoView({ block: "center", behavior: "smooth" }); await sleep(420);
    const r = el.getBoundingClientRect();
    cursor.style.left = (r.left + Math.min(r.width / 2, 80)) + "px";
    cursor.style.top = (r.top + r.height / 2) + "px";
    await sleep(640); return el;
  }
  async function clickEl(sel) {
    const el = await moveTo(sel); if (!el) return;
    cursor.classList.add("click"); el.classList.add("mb-focus");
    el.click(); await sleep(260); cursor.classList.remove("click");
    setTimeout(() => el.classList.remove("mb-focus"), 600);
  }
  async function typeInto(sel, text, perChar = 32) {
    const el = await moveTo(sel); if (!el) return;
    el.classList.add("mb-focus"); el.focus(); el.value = "";
    for (const ch of text) { el.value += ch; el.dispatchEvent(new Event("input", { bubbles: true })); await sleep(perChar); }
    el.dispatchEvent(new Event("change", { bubbles: true }));
    setTimeout(() => el.classList.remove("mb-focus"), 600);
  }
  async function setSelect(sel, val) {
    const el = await moveTo(sel); if (!el) return;
    el.value = val; el.dispatchEvent(new Event("change", { bubbles: true }));
  }
  // slash command, done right: open the menu, then pick the option (the app inserts the token)
  async function slashSeverity(optIndex) {
    const f = await moveTo("#f-sev"); if (!f) return;
    f.classList.add("mb-focus"); f.focus(); f.value = "/";
    f.dispatchEvent(new Event("input", { bubbles: true }));
    f.dispatchEvent(new KeyboardEvent("keydown", { key: "/", bubbles: true }));
    await sleep(650); // let the premium menu animate in
    const opts = document.querySelectorAll("#slashmenu .opt");
    if (opts[optIndex]) { opts[optIndex].click(); }
    await sleep(350); f.classList.remove("mb-focus");
  }

  const RECORDS = [
    { title: "Checkout latency spike", sev: 0, team: "Payments", service: "checkout-api", notes: "5xx spike on /charge after the 14:02 deploy", page: true },
    { title: "Search results timing out", sev: 1, team: "Platform", service: "search-svc", notes: "p99 > 3s; thread pool saturated", page: false },
    { title: "Image CDN cache misses", sev: 2, team: "Infrastructure", service: "img-cdn", notes: "Edge cache hit-rate dropped to 40%", page: false },
  ];

  async function doRecord(r, n) {
    $("#main").scrollTo({ top: 0, behavior: "smooth" }); await sleep(300);
    await typeInto("#f-title", r.title);
    await slashSeverity(r.sev);
    await setSelect("#f-team", r.team);
    $("#main").scrollTo({ top: 700, behavior: "smooth" }); await sleep(500);
    await typeInto("#f-service", r.service);
    await typeInto("#f-notes", r.notes, 14);
    if (r.page) await clickEl("#f-page");
    say("Monkeybot", "ok", `✓ Logging incident #${n} — title, severity, team, service, notes.`);
    await clickEl("#f-submit"); await sleep(700);
  }

  async function run() {
    document.getElementById("mb-start")?.remove();
    await sleep(400);
    // ---- Attempt 1: tries on its own, fumbles ----
    say("Monkeybot", "bot", "New task: log this incident. Let me try…");
    await sleep(1100);
    $("#main").scrollTo({ top: 0 });
    await typeInto("#f-title", "Checkout latency spike");
    await typeInto("#f-sev", "high priority");           // WRONG: ignores the / slash-command
    await clickEl("#f-submit");                          // submits early, skips below-fold fields
    say("Monkeybot", "bad", "❌ I typed the severity as plain text and skipped the fields below the fold.");
    await sleep(2000);
    // ---- You coach it ----
    say("You", "you", "👩‍🏫 Use the “/” command for severity, pick the team, and fill every field below.");
    await sleep(2600);
    say("Monkeybot", "bot", "Got it. Watch — I'll do it exactly that way, every time.");
    await sleep(1500);
    // ---- Coached: repeat the rote workflow perfectly ----
    for (let i = 0; i < RECORDS.length; i++) { await doRecord(RECORDS[i], i + 1); }
    // ---- Show the result ----
    await clickEl('[data-view="queue"]'); await sleep(500);
    say("Monkeybot", "ok", "✅ Three incidents logged — identical structure. Taught once, repeated perfectly.");
    cursor.style.left = "-100px";
  }

  // floating start button + auto-run on ?demo=1
  const btn = document.createElement("button");
  btn.id = "mb-start"; btn.textContent = "▶  Run Monkeybot demo";
  btn.onclick = run; document.body.appendChild(btn);
  if (/[?&]demo=1/.test(location.search)) { window.addEventListener("load", () => setTimeout(run, 900)); }
})();
