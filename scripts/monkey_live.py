#!/usr/bin/env python3
"""Monkeybot LIVE — a real local cua-driven agent on the deployed CRM.

Observe (cua page execute_javascript) -> decide (Claude via the Worker) -> act
(cua page click_element animates the on-screen cursor; execute_javascript fills)
-> re-observe. Watch the cursor drive the CRM in realtime.

Prereqs:
  - cua-driver daemon running:  open -n -g -a CuaDriver --args serve
  - Chrome "Allow JavaScript from Apple Events" ON (scripts/boot_live_demo.sh sets this
    up via an isolated Chrome instance and opens the bare CRM).
Usage:  python3 scripts/monkey_live.py "Create a deal: Acme renewal, $48,000, owner Sam Chen, stage Qualified to buy."
"""
import json, subprocess, sys, time, urllib.request

CUA = subprocess.check_output(["bash", "-lc", "echo $HOME"]).decode().strip() + "/.local/bin/cua-driver"
WORKER = "https://clicky-proxy.byalikhani.workers.dev/chat"
MODEL = "claude-sonnet-4-6"
MAX_STEPS = 16
SESSION = "monkeylive"

def cua(tool, args):
    out = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True)
    return out.stdout.strip(), out.stderr.strip()

def find_window():
    out, _ = cua("list_windows", {})
    wins = [w for w in json.loads(out)["windows"]
            if ("HubSpot" in (w.get("title") or "") or "Deals" in (w.get("title") or "")) and w["is_on_screen"]]
    wins.sort(key=lambda w: -w["z_index"])
    if not wins:
        print("No CRM window found — open the bare CRM first (scripts/boot_live_demo.sh)."); sys.exit(1)
    return wins[0]["pid"], wins[0]["window_id"]

def page(pid, wid, action, **kw):
    args = {"action": action, "pid": pid, "window_id": wid, **kw}
    out, err = cua("page", args)
    return out, err

def js(pid, wid, code):
    out, _ = page(pid, wid, "execute_javascript", javascript=code)
    return out

def observe(pid, wid):
    code = r"""
    (function(){
      const view=(document.querySelector('.nav button.active')||{}).dataset?.view||'new';
      const fields=[...document.querySelectorAll('input[type=text],textarea,select,input[type=checkbox]')]
        .filter(e=>e.id && e.offsetParent!==null && !e.closest('#mb-bar'))
        .map(e=>{const lab=document.querySelector('label[for="'+e.id+'"]');
          const main=document.querySelector('#main'); const r=e.getBoundingClientRect();
          const below=main? r.top>main.getBoundingClientRect().bottom:false;
          let kind=e.tagName==='SELECT'?'select':(e.type==='checkbox'?'checkbox':'text');
          let opts=e.tagName==='SELECT'?[...e.options].map(o=>o.value).filter(Boolean):undefined;
          const slash=(e.id==='f-stage');
          return {id:e.id,label:(lab?lab.textContent.trim():e.id),kind,value:e.type==='checkbox'?e.checked:e.value,below,opts,slash};});
      const qn=(document.querySelector('#queue-count')||{}).textContent||'0';
      return JSON.stringify({view,fields,queue:qn});
    })()"""
    raw = js(pid, wid, code)
    try: return raw if raw.startswith("{") else json.loads(raw)  # cua returns the JS string
    except Exception: return raw

SYSTEM = """You are Monkeybot, a teachable agent operating a HubSpot-style CRM by emitting EXACTLY ONE JSON object per turn (no prose, no fences).
Actions: {"action":"set_field","id":..,"value":..,"say":..} | {"action":"select_field","id":..,"value":..,"say":..} | {"action":"slash_field","id":"f-stage","level":"appointment|qualified|presentation|decision|closedwon|closedlost","say":..} | {"action":"toggle","id":..,"say":..} | {"action":"scroll","to":"bottom|top","say":..} | {"action":"submit","say":..} | {"action":"navigate","view":..,"say":..} | {"action":"done","summary":..,"say":..}
Fill the fields the task needs, then submit. Fields marked below=true need scroll:bottom first. f-stage is a "/" slash field — use slash_field. Keep "say" terse, first person. Follow any COACHING exactly. Re-read the observation each turn; don't redo correct fields."""

def decide(task, observation, coaching):
    user = f"TASK: {task}\n\nOBSERVATION:\n{observation}"
    if coaching: user += "\n\nCOACHING (follow exactly):\n- " + "\n- ".join(coaching)
    user += "\n\nReply with ONE JSON action."
    body = json.dumps({"model": MODEL, "max_tokens": 400, "system": SYSTEM,
                       "messages": [{"role": "user", "content": user}]}).encode()
    req = urllib.request.Request(WORKER, data=body, headers={
        "content-type": "application/json",
        "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 monkeybot-live",
    })
    data = json.loads(urllib.request.urlopen(req, timeout=30).read())
    text = "".join(b.get("text", "") for b in data.get("content", [])).strip()
    s = text.find("{"); e = text.rfind("}")
    return json.loads(text[s:e+1])

def execute(pid, wid, a):
    act = a.get("action")
    if act == "set_field":
        page(pid, wid, "click_element", selector="#" + a["id"])
        js(pid, wid, f"(function(){{const e=document.querySelector('#{a['id']}');e.focus();e.value={json.dumps(a.get('value',''))};e.dispatchEvent(new Event('input',{{bubbles:true}}));e.dispatchEvent(new Event('change',{{bubbles:true}}));}})()")
    elif act == "select_field":
        page(pid, wid, "click_element", selector="#" + a["id"])
        js(pid, wid, f"(function(){{const e=document.querySelector('#{a['id']}');e.value={json.dumps(a.get('value',''))};e.dispatchEvent(new Event('change',{{bubbles:true}}));}})()")
    elif act == "slash_field":
        page(pid, wid, "click_element", selector="#f-stage")  # cursor to the field
        lvl = a.get("level", "qualified")
        # open the menu AND select the option in-page (opt.click fires the real handler reliably)
        js(pid, wid, "(function(){var f=document.querySelector('#f-stage');f.focus();f.value='/';"
                     "f.dispatchEvent(new Event('input',{bubbles:true}));"
                     "f.dispatchEvent(new KeyboardEvent('keydown',{key:'/',bubbles:true}));"
                     "var o=document.querySelector('#slashmenu .opt[data-val=\\\"" + lvl + "\\\"]');"
                     "if(o){o.click();}})()")
        time.sleep(0.4)
    elif act == "toggle":
        page(pid, wid, "click_element", selector="#" + a["id"])
    elif act == "scroll":
        js(pid, wid, f"document.querySelector('#main').scrollTo({{top:{800 if a.get('to')=='bottom' else 0},behavior:'smooth'}})")
        time.sleep(0.6)
    elif act == "submit":
        page(pid, wid, "click_element", selector="#f-submit"); time.sleep(0.8)
    elif act == "navigate":
        page(pid, wid, "click_element", selector=f'[data-view="{a.get("view","queue")}"]'); time.sleep(0.5)

def main():
    task = sys.argv[1] if len(sys.argv) > 1 else "Create a deal: Acme Corp annual renewal, $48,000, owner Sam Chen, stage Qualified to buy, close 09/30/2026, type Renewal."
    coaching = sys.argv[2:]  # optional coaching lines
    pid, wid = find_window()
    cua("start_session", {"session": SESSION})
    print(f"Driving CRM pid={pid} window={wid}\nTASK: {task}\n")
    try:
        for step in range(1, MAX_STEPS + 1):
            obs = observe(pid, wid)
            try: a = decide(task, obs, coaching)
            except Exception as e: print("decide error:", e); break
            print(f"[{step}] {a.get('action')}  —  {a.get('say','')}")
            if a.get("action") == "done": print("DONE:", a.get("summary", "")); break
            execute(pid, wid, a)
            time.sleep(0.4)
    finally:
        cua("end_session", {"session": SESSION})

if __name__ == "__main__":
    main()
