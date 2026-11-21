import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ScreenCaptureKit

private let usage = "Usage: playtest-recorder --pid PID --output PATH.mp4 [--title TITLE] [--duration SECONDS]"
private let permissionMessage = "Playtest video needs permission in System Settings → Privacy & Security → Screen & System Audio Recording. Enable it for the launcher’s Terminal app and reopen Terminal. Game telemetry is still available."
private let byteLimit = 1_073_741_824
private let pollNanos: UInt64 = 500_000_000

private struct RecorderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private struct Options {
    var pid: pid_t = 0
    var output: URL?
    var title = "Crowfield prototype"
    var duration: Double?

    init(_ arguments: [String]) throws {
        var args = arguments.makeIterator()
        while let flag = args.next() {
            guard let value = args.next(), !value.isEmpty else { throw RecorderError(usage) }
            switch flag {
            case "--pid": pid = pid_t(value) ?? 0
            case "--output": output = URL(fileURLWithPath: value).standardizedFileURL
            case "--title": title = value
            case "--duration":
                guard let seconds = Double(value), seconds.isFinite, seconds > 0 else { throw RecorderError(usage) }
                duration = seconds
            default: throw RecorderError(usage)
            }
        }
        guard pid > 0, output?.pathExtension.lowercased() == "mp4" else { throw RecorderError(usage) }
    }
}

private func log(_ message: String, error: Bool = false) {
    let output = error ? FileHandle.standardError : FileHandle.standardOutput
    output.write(Data("\(message)\n".utf8))
}

private func clockStamp() -> String {
    let wall = Int64(Date().timeIntervalSince1970 * 1_000)
    let monotonic = DispatchTime.now().uptimeNanoseconds / 1_000
    return "wall_unix_ms=\(wall) monotonic_usec=\(monotonic)"
}

private func screenCaptureAllowed() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    let sentinel = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/Godot/app_userdata/Crowfield/.screen-recording-permission-requested"
    )
    // Claim the one-time prompt before asking, including across parallel runs.
    let fd = open(sentinel.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
    guard fd >= 0 else { return false }
    close(fd)
    log("requesting_screen_recording_permission \(clockStamp())")
    return CGRequestScreenCaptureAccess()
}

@MainActor
private func initializeWindowServer() throws {
    // ScreenCaptureKit's single-window filter uses the process's WindowServer
    // connection. Set it up through AppKit without activating a UI process.
    let application = NSApplication.shared
    guard application.activationPolicy() == .prohibited || application.setActivationPolicy(.prohibited) else {
        throw RecorderError("Could not initialize the background recorder.")
    }
}

private final class StopMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?
    private var signalSources: [DispatchSourceSignal] = []
    private let processSource: DispatchSourceProcess

    init(pid: pid_t) {
        processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        for number in [SIGHUP, SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.stop("signal_\(number)") }
            source.resume()
            signalSources.append(source)
        }
        processSource.setEventHandler { [weak self] in self?.stop("game_exited") }
        processSource.resume()
        if kill(pid, 0) == -1 && errno == ESRCH { stop("game_exited") }
    }

    deinit {
        processSource.cancel()
        for source in signalSources { source.cancel() }
    }

    func stop(_ why: String) { lock.withLock { if reason == nil { reason = why } } }
    var requested: String? { lock.withLock { reason } }
}

@available(macOS 15.0, *)
private final class RecordingEvents: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var streamStopped = false
    var completion: Result<Void, Error>? { lock.withLock { result } }
    var hasStoppedStream: Bool { lock.withLock { streamStopped } }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        log("recording_started \(clockStamp())")
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        lock.withLock { result = .failure(error) }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { result = .success(()) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { streamStopped = true }
        log("recording_stream_stopped \(clockStamp()) \(error.localizedDescription)")
    }
}

private func availableBytes(_ directory: URL) throws -> Int {
    // Use a fresh URL so subsequent reads do not reuse a cached capacity.
    let url = URL(fileURLWithPath: directory.path, isDirectory: true)
    guard let bytes = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else {
        throw RecorderError("Cannot check disk space for video.")
    }
    return bytes
}

private func preservePartialClip(_ temporary: URL, output: URL) {
    let files = FileManager.default
    guard files.fileExists(atPath: temporary.path) else { return }
    guard let size = (try? files.attributesOfItem(atPath: temporary.path)[.size]) as? NSNumber else {
        log("recording_partial path=\(temporary.path) \(clockStamp())", error: true)
        return
    }
    if size.int64Value == 0 {
        try? files.removeItem(at: temporary)
        return
    }
    let partial = output.deletingPathExtension().appendingPathExtension("partial.mp4")
    do {
        try files.moveItem(at: temporary, to: partial)
        log("recording_partial path=\(partial.path) \(clockStamp())", error: true)
    } catch {
        // Keep the uniquely named file if the partial destination exists.
        log("recording_partial path=\(temporary.path) \(clockStamp())", error: true)
    }
}

@available(macOS 15.0, *)
@MainActor
private func findGameWindow(_ options: Options, stop: StopMonitor) async throws -> SCWindow? {
    let deadline = ProcessInfo.processInfo.systemUptime + 60
    while stop.requested == nil && ProcessInfo.processInfo.systemUptime < deadline {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let matches = content.windows.filter {
            $0.owningApplication?.processID == options.pid && $0.title == options.title &&
            $0.windowLayer == 0 && $0.isOnScreen && !$0.frame.isEmpty
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw RecorderError("Two game windows matched. Video was skipped.") }
        try await Task.sleep(nanoseconds: pollNanos)
    }
    if stop.requested != nil { return nil }
    throw RecorderError("The launched game window did not become available within 60 seconds. Video was skipped.")
}

@available(macOS 15.0, *)
@MainActor
private func record(_ options: Options, output: URL) async throws {
    let stop = StopMonitor(pid: options.pid)
    let directory = output.deletingLastPathComponent()
    guard try availableBytes(directory) > byteLimit else { throw RecorderError("Video needs more than 1 GiB of free disk space.") }
    guard let window = try await findGameWindow(options, stop: stop), stop.requested == nil else { return }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let size = filter.contentRect.size
    guard size.width > 0, size.height > 0 else { throw RecorderError("The game window has no capture area.") }
    let scale = min(1.0, 1280.0 / size.width, 720.0 / size.height)
    let config = SCStreamConfiguration()
    config.width = max(2, Int(size.width * scale) / 2 * 2)
    config.height = max(2, Int(size.height * scale) / 2 * 2)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 24)
    config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    config.captureResolution = .nominal
    config.ignoreShadowsSingleWindow = true
    config.includeChildWindows = false
    config.showsCursor = false
    config.capturesAudio = false
    config.captureMicrophone = false

    let temporary = directory.appendingPathComponent(".gameplay-\(UUID().uuidString).mp4")
    defer { preservePartialClip(temporary, output: output) }
    let outputConfig = SCRecordingOutputConfiguration()
    outputConfig.outputURL = temporary
    outputConfig.videoCodecType = .h264
    outputConfig.outputFileType = .mp4
    let events = RecordingEvents()
    let recording = SCRecordingOutput(configuration: outputConfig, delegate: events)
    let stream = SCStream(filter: filter, configuration: config, delegate: events)
    try stream.addRecordingOutput(recording)
    log("window_selected game_pid=\(options.pid) window_id=\(window.windowID) width=\(config.width) height=\(config.height) fps=24 \(clockStamp())")
    try await stream.startCapture()

    let start = ProcessInfo.processInfo.systemUptime
    while stop.requested == nil && events.completion == nil && !events.hasStoppedStream {
        if ((try? availableBytes(directory)) ?? 0) <= byteLimit {
            stop.stop("disk_headroom")
        } else if recording.recordedFileSize >= byteLimit {
            stop.stop("file_limit")
        } else if let duration = options.duration, ProcessInfo.processInfo.systemUptime - start >= duration {
            stop.stop("duration_limit")
        } else {
            try await Task.sleep(nanoseconds: pollNanos)
        }
    }

    log("recording_stopping reason=\(stop.requested ?? "stream_ended") \(clockStamp())")
    // A window closing can end the stream before stopCapture is called. The
    // recording delegate determines whether the MP4 was finalized either way.
    try? await stream.stopCapture()
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while events.completion == nil && ProcessInfo.processInfo.systemUptime < deadline {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard let completion = events.completion else { throw RecorderError("The video did not finish writing.") }
    try completion.get()
    try FileManager.default.moveItem(at: temporary, to: output)
    let duration = recording.recordedDuration.seconds
    let durationMs = duration.isFinite ? Int64(duration * 1000) : 0
    log("recording_saved duration_ms=\(durationMs) \(clockStamp())")
}

@main
private struct PlaytestRecorder {
    @MainActor
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            log(usage)
            log("Use --check-permission by itself to check without requesting macOS permission.")
            return
        }
        guard #available(macOS 15.0, *) else {
            log("Playtest video requires macOS 15 or newer. Game telemetry is still available.", error: true)
            exit(69)
        }
        if args == ["--check-permission"] {
            if CGPreflightScreenCaptureAccess() { return }
            log(permissionMessage, error: true)
            exit(77)
        }
        let options: Options
        do { options = try Options(args) }
        catch { log(error.localizedDescription, error: true); exit(64) }
        guard let output = options.output, !FileManager.default.fileExists(atPath: output.path) else {
            log("Video destination already exists. Video was skipped.", error: true)
            exit(73)
        }
        guard kill(options.pid, 0) == 0 else {
            log("The launched game has already exited. Video was skipped.", error: true)
            exit(69)
        }
        do {
            try initializeWindowServer()
            guard screenCaptureAllowed() else {
                log(permissionMessage, error: true)
                exit(77)
            }
            try await record(options, output: output)
        } catch {
            log("Video unavailable: \(error.localizedDescription)", error: true)
            exit(1)
        }
    }
}
