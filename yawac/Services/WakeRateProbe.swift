import Darwin
import Foundation
import os

/// Per-second wake-rate sampler. Calls `task_info(... TASK_POWER_INFO ...)`
/// to read the kernel's count of CPU wakes attributed to this process,
/// then logs the delta per sample window. Matches the same counter the
/// kernel uses for its "caught waking the CPU N times over Ms" violation,
/// so we can see which app activity drives the wake rate.
enum WakeRateProbe {
    private static let log = Logger(subsystem: "dev.vadikas.yawac.yawac",
                                    category: "perf")
    private static var lastWakes: UInt64 = 0
    private static var lastInterrupts: UInt64 = 0
    private static var lastSampleTime: TimeInterval = 0
    private static var timerSource: DispatchSourceTimer?

    static func start() {
        guard timerSource == nil else { return }
        let q = DispatchQueue(label: "yawac.wake-probe", qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { sample() }
        timerSource = t
        t.resume()
    }

    private static func sample() {
        var info = task_power_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_power_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                task_info(mach_task_self_,
                          task_flavor_t(TASK_POWER_INFO),
                          p, &count)
            }
        }
        if kr != KERN_SUCCESS { return }
        let now = CFAbsoluteTimeGetCurrent()
        let platformIdle = UInt64(info.task_platform_idle_wakeups)
        let interrupts = UInt64(info.task_interrupt_wakeups)
        if lastSampleTime == 0 {
            lastSampleTime = now
            lastWakes = platformIdle
            lastInterrupts = interrupts
            return
        }
        let elapsed = now - lastSampleTime
        let dIdle = platformIdle &- lastWakes
        let dInt = interrupts &- lastInterrupts
        lastSampleTime = now
        lastWakes = platformIdle
        lastInterrupts = interrupts
        guard elapsed > 0 else { return }
        let idleRate = Double(dIdle) / elapsed
        let intRate = Double(dInt) / elapsed
        log.log("wakeRate idle=\(idleRate, format: .fixed(precision: 0), privacy: .public)/s int=\(intRate, format: .fixed(precision: 0), privacy: .public)/s (dIdle=\(dIdle, privacy: .public) dInt=\(dInt, privacy: .public) elapsed=\(elapsed, format: .fixed(precision: 2), privacy: .public)s)")
    }
}
