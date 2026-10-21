import AppKit

// 디버그: `Pokey --dump <bundle id>` — 그 앱에서 찾은 요소 수와 걸린 시간을 찍고 끝낸다.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--dump" {
    let bundle = CommandLine.arguments[2]
    guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        print("not running: \(bundle)")
        exit(1)
    }
    AXCollector.shared.refreshExtras()
    Thread.sleep(forTimeInterval: 1.5)
    let start = Date()
    AXCollector.shared.collect(pid: target.processIdentifier, bundleID: bundle, screens: Screens.all) { targets in
        let rects = targets.map(\.rect)
        print("targets=\(rects.count) inputs=\(targets.filter(\.isInput).count) ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        let menubar = rects.filter { $0.minY < 40 }.count
        print("menubar-ish=\(menubar)")
        if let region = ProcessInfo.processInfo.environment["REGION"]?.split(separator: ",").compactMap({ Double($0) }),
            region.count == 4
        {
            let area = CGRect(x: region[0], y: region[1], width: region[2], height: region[3])
            let inside = rects.filter { area.intersects($0) }
            print("in region: \(inside.count)")
            for r in inside { print("  \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))") }
        }
        for r in rects.prefix(8) { print("  \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))") }
        exit(0)
    }
    RunLoop.main.run()
}

// README 스크린샷: `Pokey --shot <bundle id> <out dir>` — Shot.swift.
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--shot" {
    _ = NSApplication.shared
    MainActor.assumeIsolated { Shot.run(bundle: CommandLine.arguments[2], outDir: CommandLine.arguments[3]) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
