#!/usr/bin/env python3
"""Live end-to-end proof on the real screen (needs ~2 minutes hands-off).

M1: films Safari, Finder and Hermes scrolling stock vs Glide, checks phases + trackpad passthrough
in the receiver window, measures latency / CPU / RAM, kills Glide mid-fling to prove input returns
to stock. M3: button click -> Mission Control, drag gesture -> dock swipe. Results -> /tmp/glide-live/.
Usage: python3 tools/m1-live.py [m1|m3|menu|all]
"""
import json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
B = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip() + "/Glide"
T = os.environ.get("TMPDIR", "/tmp")
OUT = "/tmp/glide-live"
os.makedirs(OUT, exist_ok=True)
FIX = os.path.join(ROOT, "tools/fixtures/long.html")
report = []


def sh(cmd, check=False, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, **kw)


def osa(script):
    return sh(["osascript", "-e", script]).stdout.strip()


def log(line):
    print(line, flush=True)
    report.append(line)


def front(app):
    osa(f'tell application "{app}" to activate')
    time.sleep(1.6)


def film(label, x, y, h, *inj, env=None):
    sh([os.path.join(ROOT, "tools/m1-film.sh"), str(x), str(y), str(h), label, *map(str, inj)], env=env)
    r = sh(["python3", os.path.join(ROOT, "tools/film-summary.py"), label]).stdout.strip()
    log("  " + r)
    return r


def probe_start(seconds=40, extra_env=None):
    env = dict(os.environ, **(extra_env or {}))
    f = open(f"{OUT}/probe.out", "w")
    p = subprocess.Popen([B, "--probe", str(seconds)], stdout=f, stderr=subprocess.STDOUT, env=env)
    time.sleep(1.2)
    return p


def probe_stop(p):
    p.terminate()  # SIGTERM -> probe prints its summary
    try:
        p.wait(3)
    except Exception:
        p.kill()
    out = open(f"{OUT}/probe.out").read()
    lat = [l for l in out.splitlines() if "latency" in l]
    last = [l for l in out.splitlines() if l.startswith("PROBE t=")][-1:]
    return out, lat, last


def app_bench(name, x, y, h, prep=None):
    log(f"== {name}")
    if prep:
        prep()
    for lab, args in [("stock-1", (1, 0.05, "down")), ("stock-12", (12, 0.03, "down"))]:
        film(f"{name}-{lab}", x, y, h, *args)
        time.sleep(0.4)
    p = probe_start(60)
    for lab, args in [("glide-1", (1, 0.05, "down")), ("glide-12", (12, 0.03, "down")), ("glide-12up", (12, 0.03, "up"))]:
        film(f"{name}-{lab}", x, y, h, *args)
        time.sleep(0.6)
    out, lat, last = probe_stop(p)
    log("  probe: " + " | ".join(last + lat))


def m1():
    # Safari
    sh(["open", "-a", "Safari", FIX]); time.sleep(2)
    osa('tell application "Safari" to set bounds of front window to {200, 60, 1000, 860}')
    front("Safari")
    app_bench("safari", 420, 470, 560)
    # rubber band at the top edge
    osa('tell application "System Events" to key code 126 using {command down}'); time.sleep(0.8)
    p = probe_start(20)
    film("safari-rubberband-top", 420, 470, 560, 4, 0.03, "up")
    probe_stop(p)
    # Finder
    sh(["open", "/System/Library/Frameworks"]); time.sleep(1.5)
    osa('tell application "Finder" to set bounds of front window to {200, 60, 1000, 860}')
    osa('tell application "Finder" to set current view of front window to list view')
    front("Finder")
    app_bench("finder", 330, 470, 560)
    osa('tell application "Finder" to close front window')
    # Hermes (Electron): move up into history first so both directions have room
    front("Hermes")
    sh([os.path.join(ROOT, "tools/m1-film.sh"), "760", "420", "520", "hermes-prep", "40", "0.02", "up"])
    time.sleep(1)
    app_bench("hermes", 760, 420, 520)


def receiver_checks():
    log("== receiver (event-level phases, trackpad passthrough, crash safety, CPU)")
    front("Safari")
    rx = f"{OUT}/rx.jsonl"
    if os.path.exists(rx):
        os.remove(rx)
    r = subprocess.Popen([B, "--receiver", rx], stdout=subprocess.PIPE, text=True)
    time.sleep(1.5)
    sh([f"{T}/warp", "720", "360"]); time.sleep(0.3)
    p = probe_start(60)
    sh([B, "--inject", "1", "0.05", "down"]); time.sleep(0.9)
    sh([B, "--inject", "12", "0.03", "down"]); time.sleep(1.8)
    n_before = len(open(rx).read().splitlines())
    sh([B, "--inject", "10", "0.016", "down", "continuous"]); time.sleep(0.5)
    sh([B, "--inject", "6", "0.05", "up", "flags=shift"]); time.sleep(1.2)
    sh([B, "--inject", "4", "0.08", "up", "flags=cmd"]); time.sleep(1.0)
    L = [json.loads(l) for l in open(rx)]
    glide = [l for l in L if l["mark"] == 0x474C494445]
    test = [l for l in L if l["mark"] == 0x7E57]
    phases = [(l["phase"], l["mphase"]) for l in glide]
    log(f"  glide events={len(glide)} precise={all(l['precise'] for l in glide)} "
        f"began={sum(1 for p_ in phases if p_[0] == 1)} changed={sum(1 for p_ in phases if p_[0] == 4)} "
        f"ended={sum(1 for p_ in phases if p_[0] == 8)} mayBegin/cancel={sum(1 for p_ in phases if p_[0] in (32, 16))} "
        f"momentum={sum(1 for p_ in phases if p_[1] != 0)}")
    log(f"  NSEvent phase values seen: {sorted(set(phases))}")
    tp = [l for l in test if l["precise"] == 1]
    log(f"  trackpad-like continuous events delivered untouched: {len(tp)}/10 (dy={sorted(set(l['dy'] for l in tp))})")
    hz = [l for l in glide if abs(l["dx"]) > 0 and l["dy"] == 0]
    log(f"  shift -> horizontal glide events: {len(hz)}")
    # delivery latency: event creation -> app received
    dl = sorted((l["t"] - l["ets"]) * 1000 for l in glide if l["ets"] > 0)
    if dl:
        log(f"  post->app delivery ms p50={dl[len(dl)//2]:.2f} p95={dl[int(len(dl)*.95)]:.2f}")
    # CPU while scrolling continuously (300 ticks ~10 s) and idle
    pid = p.pid
    inj = subprocess.Popen([B, "--inject", "300", "0.033", "down"], stdout=subprocess.DEVNULL)
    time.sleep(2)
    top = sh(["top", "-l", "6", "-s", "1", "-pid", str(pid), "-stats", "pid,cpu,mem"]).stdout
    inj.wait()
    vals = [float(m) for m in re.findall(rf"^{pid}\s+([\d.]+)", top, re.M)][1:]
    mems = re.findall(rf"^{pid}\s+[\d.]+\s+(\S+)", top, re.M)
    log(f"  CPU while scrolling continuously: {vals} % (mem {mems[-1] if mems else '?'})")
    time.sleep(3)
    top = sh(["top", "-l", "4", "-s", "1", "-pid", str(pid), "-stats", "pid,cpu,mem"]).stdout
    vals = [float(m) for m in re.findall(rf"^{pid}\s+([\d.]+)", top, re.M)][1:]
    log(f"  CPU idle: {vals} %")
    out, lat, last = probe_stop(p)
    log("  " + " | ".join(lat + last))
    # crash safety: kill -9 mid-fling, then input must be stock immediately
    open(rx, "w").close()
    p = probe_start(30)
    subprocess.Popen([B, "--inject", "12", "0.02", "down"], stdout=subprocess.DEVNULL)
    time.sleep(0.15)
    p.kill(); p.wait()
    time.sleep(0.6)
    t_kill = time.time()
    sh([B, "--inject", "5", "0.02", "down", "continuous"])
    sh([B, "--inject", "3", "0.05", "down"])
    time.sleep(0.6)
    L = [json.loads(l) for l in open(rx)]
    after = [l for l in L if l["mark"] == 0x7E57]
    log(f"  after kill -9 mid-fling: stock events delivered={len(after)}/8 "
        f"(continuous={sum(1 for l in after if l['precise'])}, discrete={sum(1 for l in after if not l['precise'])})")
    r.terminate()


def m3():
    log("== M3 gestures (button 4 click -> Mission Control, button 5 drag up -> dock swipe)")
    front("Safari")
    settings = {"remapsEnabled": True,
                "remaps": [{"button": 4, "trigger": "click", "action": {"missionControl": {}}}],
                "dragGestureButton": 5}
    p = probe_start(40, {"GLIDE_SETTINGS_JSON": json.dumps(settings)})
    sh([f"{T}/warp", "600", "450"])
    sh([B, "--button", "4", "down"]); time.sleep(0.05); sh([B, "--button", "4", "up"])
    time.sleep(1.2)
    sh(["screencapture", "-x", f"{OUT}/m3-mission-control.png"])
    osa('tell application "System Events" to key code 53'); time.sleep(1.0)
    sh([B, "--button", "5", "down"])
    for _ in range(25):
        sh([B, "--button", "5", "drag", "0", "-14"]); time.sleep(0.012)
    time.sleep(0.4)
    sh(["screencapture", "-x", f"{OUT}/m3-dockswipe-mid.png"])
    sh([B, "--button", "5", "up"]); time.sleep(1.2)
    sh(["screencapture", "-x", f"{OUT}/m3-dockswipe-end.png"])
    osa('tell application "System Events" to key code 53'); time.sleep(0.8)
    out, lat, last = probe_stop(p)
    log("  probe: " + " | ".join(last) + "  (screens: m3-*.png)")


def menu():
    log("== menu on screen")
    front("Safari")
    sh(["pkill", "-x", "Glide"]); time.sleep(1.5)
    sh(["open", "/Applications/Glide.app", "--args", "--open-menu"]); time.sleep(2.5)
    sh(["screencapture", "-x", f"{OUT}/menu-full.png"])
    osa('tell application "System Events" to key code 53'); time.sleep(0.4)
    log("  screenshot: menu-full.png")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    old = sh([f"{T}/cur"]).stdout.strip().strip("()").replace(" ", "")
    frontmost = osa('tell application "System Events" to get name of first process whose frontmost is true')
    sh(["pkill", "-x", "Glide"])
    try:
        if what in ("m1", "all"):
            m1(); receiver_checks()
        if what in ("m3", "all"):
            m3()
        if what in ("menu", "all"):
            menu()
    finally:
        if "," in old:
            x, y = old.split(",")
            sh([f"{T}/warp", x, y])
        if not sh(["pgrep", "-x", "Glide"]).stdout.strip():
            sh(["open", "/Applications/Glide.app"])
        front("Hermes")
        open(f"{OUT}/report.txt", "w").write("\n".join(report) + "\n")
        print(f"report -> {OUT}/report.txt (front app before: {frontmost})")
