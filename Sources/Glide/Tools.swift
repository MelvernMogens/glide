import AppKit
import GlideKit

/// Headless verification tools. None of these touch the user's saved settings.
enum Tools {
    static let testMark: Int64 = 0x7E57 // marks injected "hardware" ticks (not Glide output)

    /// `glide --probe [seconds]`: run the tap with default settings, print counters every second and
    /// latency percentiles at the end.
    static func probe(seconds: Double) -> Never {
        var s = GlideSettings()
        if let v = ProcessInfo.processInfo.environment["GLIDE_SMOOTHNESS"], let sm = Smoothness(rawValue: v) { s.smoothness = sm }
        if ProcessInfo.processInfo.environment["GLIDE_REVERSE"] == "0" { s.reverseDirection = false }
        let engine = Engine.shared
        guard engine.start(settings: s) else {
            print("PROBE FAIL: could not create event tap (Accessibility permission missing)")
            exit(2)
        }
        let systemNatural = (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString, kCFPreferencesAnyApplication) as? Bool) ?? true
        print("PROBE tap=on smoothness=\(s.smoothness.rawValue) speed=\(s.speed.rawValue) reverse=\(s.reverseDirection) trackpadSim=\(s.trackpadSimulation) systemNatural=\(systemNatural) invert=\(engine.invertDirection) refresh=\(NSScreen.main?.maximumFramesPerSecond ?? 0)Hz")
        setvbuf(stdout, nil, _IOLBF, 0)
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            engine.perform {
                print(String(format: "PROBE t=%.0fs ticksIn=%d eventsOut=%d passthrough=%d tapEnabled=%@ reenables=%d",
                             Date().timeIntervalSince(start), engine.ticksIn, engine.eventsOut, engine.passthrough,
                             engine.tapIsEnabled ? "yes" : "no", engine.tapReenables))
            }
            if Date().timeIntervalSince(start) >= seconds {
                t.invalidate()
                engine.perform {
                    let n = engine.latency.count
                    let xs = engine.latency.samples[0..<n].sorted()
                    func pct(_ p: Double) -> Double { xs.isEmpty ? 0 : xs[min(xs.count - 1, Int(Double(xs.count) * p))] * 1000 }
                    print(String(format: "PROBE latency tap->first-post (ms) n=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f frame=%.2f",
                                 n, pct(0.5), pct(0.95), pct(0.99), xs.last.map { $0 * 1000 } ?? 0, 1000.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60)))
                    exit(0)
                }
            }
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
        exit(0)
    }

    /// `glide --inject <ticks> <interval> [down|up] [continuous] [flags=cmd,opt,shift,ctrl]`
    /// Posts discrete wheel ticks at the HID level, like a real mouse would.
    static func inject(_ args: [String]) -> Never {
        let n = Int(args.first ?? "") ?? 10
        let interval = Double(args.dropFirst().first ?? "") ?? 0.05
        let up = args.contains("up")
        let continuous = args.contains("continuous")
        let horizontal = args.contains("horizontal")
        var flags: UInt64 = 0
        if let f = args.first(where: { $0.hasPrefix("flags=") }) {
            for m in f.dropFirst(6).split(separator: ",") {
                switch m { case "cmd": flags |= 1 << 20; case "opt": flags |= 1 << 19; case "shift": flags |= 1 << 17; case "ctrl": flags |= 1 << 18; default: break }
            }
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let d: Int32 = up ? 1 : -1
        var loc = CGEvent(source: nil)?.location ?? .zero
        // direct=pid,window,x,y : stock baseline, deliver straight to that window (bypasses Glide)
        var direct: (pid_t, Int64)? = nil
        if let f = args.first(where: { $0.hasPrefix("direct=") }) {
            let p = f.dropFirst(7).split(separator: ",").compactMap { Double($0) }
            if p.count == 4 { direct = (pid_t(p[0]), Int64(p[1])); loc = CGPoint(x: p[2], y: p[3]) }
        }
        func fire(_ e: CGEvent) {
            if let (pid, win) = direct {
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: win)
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: win)
                e.postToPid(pid)
            } else {
                e.post(tap: .cghidEventTap)
            }
        }
        for i in 0..<n {
            let t0 = uptime()
            if continuous {
                // Trackpad-like: precise pixel deltas with gesture phases.
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: horizontal ? 0 : d * 8, wheel2: horizontal ? d * 8 : 0, wheel3: 0)!
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: i == 0 ? 1 : (i == n - 1 ? 4 : 2))
                e.setIntegerValueField(.eventSourceUserData, value: testMark)
                e.location = loc
                e.flags = CGEventFlags(rawValue: flags)
                fire(e)
            } else {
                let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: horizontal ? 0 : d, wheel2: horizontal ? d : 0, wheel3: 0)!
                e.setIntegerValueField(.eventSourceUserData, value: testMark)
                e.location = loc
                e.flags = CGEventFlags(rawValue: flags)
                fire(e)
            }
            print(String(format: "INJECT %d t=%.6f", i, t0))
            let next = t0 + interval
            while uptime() < next { usleep(500) }
        }
        exit(0)
    }

    /// `glide --receiver <log>`: a test window (centred, never at a screen edge) with a tall scroll
    /// view that logs every scroll event it receives as JSON lines.
    static func receiver(log: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        FileManager.default.createFile(atPath: log, contents: nil)
        let fh = FileHandle(forWritingAtPath: log)!
        MainActor.assumeIsolated {
            let frame = NSRect(x: 0, y: 0, width: 520, height: 420)
            let w = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Glide Receiver"
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let sv = LoggingScrollView(frame: frame)
            sv.fh = fh
            sv.hasVerticalScroller = true
            sv.hasHorizontalScroller = true
            let doc = NSView(frame: NSRect(x: 0, y: 0, width: 3000, height: 20000))
            doc.wantsLayer = true
            doc.layer?.backgroundColor = NSColor.darkGray.cgColor
            sv.documentView = doc
            doc.scroll(NSPoint(x: 0, y: 10000))
            w.contentView = sv
            w.center()
            w.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            if let f = w.screen?.frame {
                let r = w.frame
                print(String(format: "RECEIVER center_cg=%.0f,%.0f", r.midX, f.height - r.midY))
            }
            fflush(stdout)
        }
        app.run()
        exit(0)
    }
}

final class LoggingScrollView: NSScrollView {
    var fh: FileHandle?
    override func scrollWheel(with e: NSEvent) {
        super.scrollWheel(with: e)
        let now = ProcessInfo.processInfo.systemUptime
        let y = contentView.bounds.origin.y, x = contentView.bounds.origin.x
        let c = e.cgEvent
        let line = String(format: "{\"t\":%.6f,\"ets\":%.6f,\"dy\":%.3f,\"dx\":%.3f,\"precise\":%d,\"phase\":%lu,\"mphase\":%lu,\"inv\":%d,\"y\":%.1f,\"x\":%.1f,\"mark\":%lld}\n",
                          now, e.timestamp, e.scrollingDeltaY, e.scrollingDeltaX, e.hasPreciseScrollingDeltas ? 1 : 0,
                          e.phase.rawValue, e.momentumPhase.rawValue, e.isDirectionInvertedFromDevice ? 1 : 0, y, x,
                          c?.getIntegerValueField(.eventSourceUserData) ?? -1)
        fh?.write(line.data(using: .utf8)!)
    }
}

// MARK: - scrollcam: measure real on-screen scrolling

extension Tools {
    typealias CreateImageForRect = @convention(c) (UInt32, CGRect) -> Unmanaged<CGImage>?

    /// `glide --scrollcam x y h seconds`: grab a narrow vertical strip of the screen (points, CG
    /// coordinates, top-left origin) ~120 times a second and print the content shift between
    /// consecutive frames. Rows are averaged across the strip width into a 1-D luminance profile;
    /// the shift is the offset minimising the mean absolute difference.
    static func scrollcam(x: Double, y: Double, h: Double, seconds: Double, horizontal: Bool) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImageForRect") else {
            print("SCROLLCAM FAIL no CGDisplayCreateImageForRect"); exit(1)
        }
        let grab = unsafeBitCast(sym, to: CreateImageForRect.self)
        let display = CGMainDisplayID()
        // GLIDE_CAM_WINDOW=<id>: capture that window's pixels even when it is on another Space.
        typealias WinImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let camWindow = ProcessInfo.processInfo.environment["GLIDE_CAM_WINDOW"].flatMap { UInt32($0) }
        let winGrab = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").map { unsafeBitCast($0, to: WinImage.self) }
        let rect = horizontal ? CGRect(x: x - h / 2, y: y - 20, width: h, height: 40) : CGRect(x: x - 20, y: y - h / 2, width: 40, height: h)
        func profile() -> [Double]? {
            let captured: CGImage?
            if let camWindow, let winGrab {
                // kCGWindowListOptionIncludingWindow = 1<<3, kCGWindowImageBoundsIgnoreFraming = 1
                captured = winGrab(rect, 1 << 3, camWindow, 1)?.takeRetainedValue()
            } else {
                captured = grab(display, rect)?.takeRetainedValue()
            }
            guard let img = captured else { return nil }
            let w = img.width, ht = img.height
            var buf = [UInt8](repeating: 0, count: w * ht * 4)
            guard let ctx = CGContext(data: &buf, width: w, height: ht, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: ht))
            let n = horizontal ? w : ht
            var out = [Double](repeating: 0, count: n)
            for r in 0..<ht {
                for c in 0..<w {
                    let i = (r * w + c) * 4
                    let l = 0.299 * Double(buf[i]) + 0.587 * Double(buf[i + 1]) + 0.114 * Double(buf[i + 2])
                    out[horizontal ? c : r] += l
                }
            }
            let div = Double(horizontal ? ht : w)
            return out.map { $0 / div }
        }
        func shift(_ a: [Double], _ b: [Double]) -> (Int, Double) {
            let n = a.count, maxS = min(160, n / 3)
            var best = 0, bestErr = Double.infinity
            for s in -maxS...maxS {
                var err = 0.0, cnt = 0
                let lo = max(0, -s), hi = min(n, n - s)
                var i = lo
                while i < hi { err += abs(a[i] - b[i + s]); cnt += 1; i += 1 }
                let e = err / Double(max(cnt, 1))
                if e < bestErr - 1e-9 || (abs(e - bestErr) < 1e-9 && abs(s) < abs(best)) { bestErr = e; best = s }
            }
            return (best, bestErr)
        }
        let scale = Double(NSScreen.main?.backingScaleFactor ?? 2)
        print(String(format: "SCROLLCAM start=%.6f scale=%.0f", uptime(), scale))
        var prev = profile()
        var total = 0.0
        let end = uptime() + seconds
        while uptime() < end {
            let t0 = uptime()
            guard let cur = profile() else { continue }
            if let p = prev {
                let (s, err) = shift(p, cur)
                if s != 0 {
                    total += Double(s) / scale
                    print(String(format: "SCROLLCAM t=%.6f shift=%.1f total=%.1f err=%.2f", t0, Double(s) / scale, total, err))
                }
            }
            prev = cur
            let next = t0 + 1.0 / 120
            while uptime() < next { usleep(300) }
        }
        print(String(format: "SCROLLCAM done total=%.1f", total))
        exit(0)
    }
}
