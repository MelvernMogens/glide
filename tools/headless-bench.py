#!/usr/bin/env python3
"""Headless numbers without touching the screen: Glide's output goes to a sink process
(GLIDE_TARGET) so nothing visible scrolls; injected wheel ticks are swallowed by Glide's tap.
Measures tap->post latency, idle + scrolling CPU, RAM, and that a kill -9 leaves no tap behind."""
import ctypes, ctypes.util, os, re, subprocess, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
B = subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, text=True).strip() + "/Glide"

cg = ctypes.CDLL(ctypes.util.find_library("ApplicationServices"))


class TapInfo(ctypes.Structure):
    _fields_ = [("eventTapID", ctypes.c_uint32), ("tapPoint", ctypes.c_uint32), ("options", ctypes.c_uint32),
                ("eventsOfInterest", ctypes.c_uint64), ("tappingProcess", ctypes.c_int32), ("processBeingTapped", ctypes.c_int32),
                ("enabled", ctypes.c_bool), ("minUsecLatency", ctypes.c_float), ("avgUsecLatency", ctypes.c_float),
                ("maxUsecLatency", ctypes.c_float)]


def taps_of(pid):
    n = ctypes.c_uint32()
    cg.CGGetEventTapList(0, None, ctypes.byref(n))
    arr = (TapInfo * n.value)()
    cg.CGGetEventTapList(n.value, arr, ctypes.byref(n))
    return [t for t in arr[: n.value] if t.tappingProcess == pid]


def top_cpu(pid, samples):
    out = subprocess.run(["top", "-l", str(samples + 1), "-s", "1", "-pid", str(pid), "-stats", "pid,cpu,mem"],
                         capture_output=True, text=True).stdout
    cpu = [float(x) for x in re.findall(rf"^{pid}\s+([\d.]+)", out, re.M)][1:]
    mem = re.findall(rf"^{pid}\s+[\d.]+\s+(\S+)", out, re.M)
    return cpu, (mem[-1] if mem else "?")


sink = subprocess.Popen(["sleep", "120"])
env = dict(os.environ, GLIDE_TARGET=f"{sink.pid},0,0,0")
log = open("/tmp/glide-headless-probe.out", "w")
p = subprocess.Popen([B, "--probe", "90"], stdout=log, stderr=subprocess.STDOUT, env=env)
time.sleep(1.5)
t = taps_of(p.pid)
print(f"tap installed: {len(t)} (enabled={[x.enabled for x in t]}, tapPoint={[x.tapPoint for x in t]})")
cpu, mem = top_cpu(p.pid, 4)
print(f"idle CPU {cpu} %  mem {mem}")
inj = subprocess.Popen([B, "--inject", "330", "0.03", "down"], stdout=subprocess.DEVNULL)  # ~10 s of continuous wheel
time.sleep(1.5)
cpu, mem = top_cpu(p.pid, 6)
inj.wait()
print(f"scrolling CPU {cpu} %  mem {mem}  (33 ticks/s continuous)")
t = taps_of(p.pid)
if t:
    print(f"system-measured tap latency usec: min={t[0].minUsecLatency:.0f} avg={t[0].avgUsecLatency:.0f} max={t[0].maxUsecLatency:.0f}")
time.sleep(1.0)
fp = subprocess.run(["footprint", str(p.pid)], capture_output=True, text=True).stdout
print("footprint:", " ".join(l.strip() for l in fp.splitlines() if "Footprint" in l or "phys_footprint:" in l))
p.terminate(); p.wait()
out = open("/tmp/glide-headless-probe.out").read()
print("\n".join(l for l in out.splitlines() if "latency" in l or l.startswith("PROBE tap")))
print([l for l in out.splitlines() if l.startswith("PROBE t=")][-1])

# crash safety: kill -9 in the middle of a fling, then look for leftover taps
p = subprocess.Popen([B, "--probe", "30"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
time.sleep(1.2)
before = len(taps_of(p.pid))
subprocess.Popen([B, "--inject", "12", "0.02", "down"], stdout=subprocess.DEVNULL)
time.sleep(0.15)
p.kill(); p.wait()
time.sleep(0.3)
print(f"kill -9 mid-fling: taps before={before} after={len(taps_of(p.pid))} (0 = input back to stock)")
sink.kill()
