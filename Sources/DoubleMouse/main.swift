import AppKit

let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    // Collected and not asserted: assert is compiled out of release builds, and the release
    // script runs this on the signed app it is about to ship.
    var problems: [String] = []
    func check(_ ok: Bool, _ what: String) {
        if !ok {
            problems.append(what)
        }
    }

    let raw = CGPoint(x: 3, y: 4) // speed 5
    check(scaledDelta(raw, sensitivity: 1, acceleration: false) == raw, "sensitivity 1 without acceleration must pass the delta through")
    check(scaledDelta(raw, sensitivity: 2, acceleration: false) == CGPoint(x: 6, y: 8), "sensitivity must scale both axes")
    let crawl = scaledDelta(CGPoint(x: 0.0001, y: 0), sensitivity: 1, acceleration: true)
    check(crawl.x / 0.0001 < 1.01, "slow movement must stay near 1:1")
    let sprint = scaledDelta(CGPoint(x: 100, y: 0), sensitivity: 1, acceleration: true)
    check(abs(sprint.x - 200) < 0.001, "acceleration must saturate at 2x")
    let mid = scaledDelta(CGPoint(x: 20, y: 0), sensitivity: 1, acceleration: true)
    check(mid.x > 20 && mid.x < sprint.x, "gain must rise with speed")

    // An L: a wide display with a smaller one above its left half, and a hole above the right half.
    let screens = [CGRect(x: 0, y: 0, width: 2000, height: 1000), CGRect(x: 0, y: 1000, width: 1000, height: 800)]
    check(pointOnScreens(CGPoint(x: 500, y: 1500), screens: screens) == CGPoint(x: 500, y: 1500), "a point on a display must stay put")
    let hole = pointOnScreens(CGPoint(x: 1500, y: 1010), screens: screens)
    check(screens.contains { $0.contains(hole) } && abs(hole.y - 999) < 0.001, "a point in the hole must move to the nearest display")
    let edge = pointOnScreens(CGPoint(x: 2600, y: 500), screens: screens)
    check(screens.contains { $0.contains(edge) }, "a point past the far edge must land on a display, not on its border")

    let first = (point: CGPoint(x: 10, y: 10), time: 100.0, count: Int64(1))
    check(nextClickCount(after: nil, at: first.point, time: 100, interval: 0.5) == 1, "a first press is a single click")
    check(nextClickCount(after: first, at: CGPoint(x: 12, y: 11), time: 100.3, interval: 0.5) == 2, "a quick second press nearby is a double click")
    check(nextClickCount(after: (first.point, 100.3, 2), at: first.point, time: 100.6, interval: 0.5) == 3, "a third one is a triple click")
    check(nextClickCount(after: first, at: first.point, time: 100.8, interval: 0.5) == 1, "a slow second press starts over")
    check(nextClickCount(after: first, at: CGPoint(x: 60, y: 10), time: 100.2, interval: 0.5) == 1, "a press somewhere else starts over")

    // Side buttons are numbers Quartz has no case for; they must still make a CGMouseButton.
    check(CGMouseButton(rawValue: 4) != nil, "a side button must map to a mouse button")

    problems += Updater.selfTest()
    print(problems.isEmpty ? "selftest ok" : "selftest failed\n- " + problems.joined(separator: "\n- "))
    exit(problems.isEmpty ? 0 : 1)
}

// The installer script exactly as the app writes it, to try it on copies without updating anything.
if let index = arguments.firstIndex(of: "--installer"), index + 4 < arguments.count {
    print(Updater.installer(source: arguments[index + 1], destination: arguments[index + 2], volume: arguments[index + 3], pid: Int32(arguments[index + 4]) ?? 0))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
