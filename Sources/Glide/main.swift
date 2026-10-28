import AppKit
import GlideKit

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "--probe":
    Tools.probe(seconds: Double(args.dropFirst().first ?? "") ?? 30)
case "--inject":
    Tools.inject(Array(args.dropFirst()))
case "--scrollcam":
    let a = args.dropFirst().compactMap(Double.init)
    Tools.scrollcam(x: a[0], y: a[1], h: a[2], seconds: a[3], horizontal: args.contains("horizontal"))
case "--receiver":
    Tools.receiver(log: args.dropFirst().first ?? "/tmp/glide-receiver.jsonl")
default:
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
