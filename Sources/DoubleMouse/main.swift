import AppKit

if CommandLine.arguments.contains("--selftest") {
    // The pointer scaling curve is the only logic here that can be wrong silently.
    let raw = CGPoint(x: 3, y: 4) // speed 5

    let plain = scaledDelta(raw, sensitivity: 1, acceleration: false)
    assert(plain == raw, "sensitivity 1 without acceleration must pass the delta through")

    let doubled = scaledDelta(raw, sensitivity: 2, acceleration: false)
    assert(doubled == CGPoint(x: 6, y: 8), "sensitivity must scale both axes")

    let crawl = scaledDelta(CGPoint(x: 0.0001, y: 0), sensitivity: 1, acceleration: true)
    assert(crawl.x / 0.0001 < 1.01, "slow movement must stay near 1:1")

    let sprint = scaledDelta(CGPoint(x: 100, y: 0), sensitivity: 1, acceleration: true)
    assert(abs(sprint.x - 200) < 0.001, "acceleration must saturate at 2x")

    let mid = scaledDelta(CGPoint(x: 20, y: 0), sensitivity: 1, acceleration: true)
    assert(mid.x > 20 && mid.x < sprint.x, "gain must rise with speed")

    print("selftest ok")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
