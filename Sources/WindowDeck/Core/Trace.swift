import Foundation
import Darwin

/// A durable diagnostic log, written to disk as it happens.
///
/// The point is being able to answer "what was the app doing when that went
/// wrong" *after* the fact — including after a crash, when nothing is left to
/// ask. Three properties matter, and each one rules out a simpler design:
///
/// - **Every line is on disk before the call returns to the run loop.** Buffering
///   is the obvious optimisation and it loses exactly the lines worth having:
///   the last few before the process dies. The file is opened `O_APPEND` once
///   and written with `write(2)`, so a line survives a `SIGKILL` between one
///   statement and the next.
/// - **A crash writes its own record.** A signal handler cannot allocate, take a
///   lock, or call anything that might — so the file descriptor and the frame
///   buffer are prepared at launch and the handler does nothing but `write` and
///   `backtrace_symbols_fd`. It then re-raises with the default disposition so
///   the system crash reporter still gets its report; this augments that, it
///   does not replace it.
/// - **It is off the main thread.** WindowDeck is unusually sensitive to work on
///   the keypress path — a stall there delays the *next* event, which is what
///   made a following press advance an open switcher session instead of starting
///   a new one. Formatting happens on the caller (so nothing shared is captured)
///   and the syscall is handed to a utility queue.
///
/// Volume is controlled by level, not by category, so turning tracing up never
/// requires knowing which category a bug lives in. `.info` is the default and is
/// meant to stay readable for a whole session; `.debug` is per-refresh detail and
/// is opt-in via `WINDOWDECK_TRACE=1` or the Settings toggle.
enum Trace {

    enum Level: Int, Comparable {
        case debug = 0, info = 1, warn = 2, error = 3
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var tag: String {
            switch self {
            case .debug: "DBG"
            case .info: "INF"
            case .warn: "WRN"
            case .error: "ERR"
            }
        }
    }

    /// Categories exist to make the log greppable, not to gate it.
    enum Category: String {
        case app, engine, group, member, rebind, capture
        case hotkey, state, preview, ui, perf, crash, system
    }

    // MARK: - Files

    /// Alongside `state.json`, and redirected by the same environment variable —
    /// the self-test must never write to the real location, and a log is no
    /// different from state in that respect.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["WINDOWDECK_STATE_DIR"] {
            return URL(fileURLWithPath: override).appendingPathComponent("logs", isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowDeck", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    static var logURL: URL { directory.appendingPathComponent("windowdeck.log") }
    static var previousLogURL: URL { directory.appendingPathComponent("windowdeck.previous.log") }

    /// Written at a clean shutdown and removed at launch. Its presence at launch
    /// is the only evidence that the previous run ended on its own terms —
    /// distinguishing a crash from a quit is otherwise impossible after the fact,
    /// since both simply stop producing lines.
    private static var cleanExitMarker: URL { directory.appendingPathComponent(".clean-exit") }

    /// Past this the log is rotated. One previous generation is kept, which is
    /// the same shape as the state file's backup and for the same reason: the
    /// interesting run is often the one before the one you are looking at.
    private static let rotateAtBytes = 4 * 1024 * 1024

    // MARK: - State

    private static let queue = DispatchQueue(label: "com.windowdeck.trace", qos: .utility)

    /// Read on every call from any thread and written approximately never. A
    /// lock here would cost more than the logging it guards, and the worst case
    /// of a torn read is one line logged at the wrong level.
    nonisolated(unsafe) static var minimumLevel: Level = .info

    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var startedAt = Date()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Lifecycle

    /// Call before anything else the app does. Opens the file, records why the
    /// previous session ended, and arms the crash handlers.
    static func start() {
        guard !started else { return }
        started = true
        startedAt = Date()

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rotateIfNeeded()

        let path = logURL.path
        traceFD = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard traceFD >= 0 else { return }

        let ended = previousSessionOutcome()
        try? FileManager.default.removeItem(at: cleanExitMarker)

        writeRaw("\n")
        log(.app, "─── session start ───")
        log(.app, "previous session: \(ended)",
            level: ended == "ended cleanly" ? .info : .warn)
        logEnvironment()

        installCrashHandlers()
    }

    /// Records that this run is ending deliberately. Anything that stops the
    /// process without reaching here reads as a crash on the next launch, which
    /// is the right way round to be wrong.
    static func markCleanExit() {
        log(.app, "─── session end (clean) after \(elapsed()) ───")
        FileManager.default.createFile(atPath: cleanExitMarker.path, contents: Data())
        queue.sync {}   // the marker must not beat the last line onto disk
    }

    private static func previousSessionOutcome() -> String {
        guard FileManager.default.fileExists(atPath: logURL.path) else { return "none (first run)" }
        return FileManager.default.fileExists(atPath: cleanExitMarker.path)
            ? "ended cleanly"
            : "did NOT end cleanly — crash, force quit or power loss"
    }

    private static func rotateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > rotateAtBytes else { return }
        try? FileManager.default.removeItem(at: previousLogURL)
        try? FileManager.default.moveItem(at: logURL, to: previousLogURL)
    }

    // MARK: - Logging

    static func log(_ category: Category,
                    _ message: @autoclosure () -> String,
                    level: Level = .info) {
        guard level >= minimumLevel, traceFD >= 0 else { return }
        // Formatted here, on the caller's thread, so nothing the caller owns is
        // read from another one. Only the finished string crosses the queue.
        let line = "\(formatter.string(from: Date())) \(level.tag) \(category.rawValue.padded(to: 7)) \(message())\n"
        queue.async { writeRaw(line) }
    }

    static func debug(_ c: Category, _ m: @autoclosure () -> String) { log(c, m(), level: .debug) }
    static func warn(_ c: Category, _ m: @autoclosure () -> String) { log(c, m(), level: .warn) }
    static func error(_ c: Category, _ m: @autoclosure () -> String) { log(c, m(), level: .error) }

    private static func writeRaw(_ text: String) {
        guard traceFD >= 0 else { return }
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(traceFD, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 { break }
            offset += written
        }
    }

    /// Waits for queued lines to reach the file. Only the self-test needs this:
    /// ordinary logging is deliberately fire-and-forget, so a test that read the
    /// file straight after writing would race the queue and fail intermittently.
    static func flushForTesting() { queue.sync {} }

    private static func elapsed() -> String {
        String(format: "%.0fs", Date().timeIntervalSince(startedAt))
    }

    // MARK: - Context

    /// The facts that turn "it misbehaved" into a reproducible report. Logged
    /// once per session because none of it changes within one.
    private static func logEnvironment() {
        let info = ProcessInfo.processInfo
        let bundle = Bundle.main.infoDictionary
        let version = (bundle?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (bundle?["CFBundleVersion"] as? String) ?? "?"

        log(.system, "WindowDeck \(version) (\(build)) pid \(info.processIdentifier)")
        log(.system, "macOS \(info.operatingSystemVersionString), \(info.processorCount) cores, "
            + "\(info.physicalMemory / 1_073_741_824) GB")
        log(.system, "trace level \(minimumLevel.tag), log at \(logURL.path)")
    }

    /// A periodic line saying what this process is costing.
    ///
    /// Written because "WindowDeck is making my machine slow" is a claim nobody
    /// can check afterwards without it, and because the answer has twice been
    /// something else entirely — the strip redraw rather than the engine tick,
    /// and once a system helper this app never touches. A number per minute
    /// settles it either way.
    static func heartbeat(windows: Int, groups: Int) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
                + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        let uptime = Date().timeIntervalSince(startedAt)
        let share = uptime > 0 ? cpu / uptime * 100 : 0

        log(.perf, String(format: "uptime %.0fs, cpu %.1fs (%.1f%% avg), %@, %d windows, %d groups",
                          uptime, cpu, share, footprint(), windows, groups))
    }

    private static func footprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "memory ?" }
        return String(format: "memory %.1f MB", Double(info.phys_footprint) / 1_048_576)
    }

    // MARK: - Crashes

    private static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            // Not a signal context — this runs on an ordinary thread and may
            // allocate, so the full symbolicated stack is available here.
            Trace.writeRaw("\n*** UNCAUGHT EXCEPTION ***\n")
            Trace.writeRaw("name: \(exception.name.rawValue)\n")
            Trace.writeRaw("reason: \(exception.reason ?? "none")\n")
            for frame in exception.callStackSymbols { Trace.writeRaw("  \(frame)\n") }
            Trace.writeRaw("*** END EXCEPTION ***\n")
        }

        for signal in fatalSignals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = crashSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(signal, &action, nil)
        }
    }
}

// MARK: - Signal-handler globals

/// The descriptor the crash handler writes to. Opened once at `start()` because
/// opening a file inside a signal handler is not permitted — by then the process
/// may hold the allocator lock it would need.
nonisolated(unsafe) private var traceFD: Int32 = -1

/// Pre-allocated so the handler never calls `malloc`, which would deadlock if
/// the crash happened inside the allocator — which is exactly where a
/// heap-corruption crash does happen.
nonisolated(unsafe) private var frameBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>
    .allocate(capacity: 128)

private let fatalSignals: [Int32] = [SIGILL, SIGTRAP, SIGABRT, SIGFPE, SIGBUS, SIGSEGV, SIGSYS]

/// Deliberately a bare C function: only `write(2)` and `backtrace_symbols_fd`
/// are used, both of which are safe to call after a fatal signal. Anything that
/// allocates — string interpolation, `Date`, `NSLog` — can deadlock here and
/// would cost the very report it was trying to write.
private let crashSignalHandler: @convention(c) (Int32) -> Void = { signalNumber in
    if traceFD >= 0 {
        let header = "\n*** FATAL SIGNAL \(signalNumber) ***\n"
        _ = header.withCString { write(traceFD, $0, strlen($0)) }

        let depth = backtrace(frameBuffer, 128)
        backtrace_symbols_fd(frameBuffer, depth, traceFD)

        let footer = "*** END SIGNAL ***\n"
        _ = footer.withCString { write(traceFD, $0, strlen($0)) }
        fsync(traceFD)
    }

    // Hand it back to the system so the real crash report is still produced.
    // Swallowing the signal would trade a proper report for this summary.
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

private extension String {
    /// Keeps the category column aligned so the log stays scannable by eye.
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
