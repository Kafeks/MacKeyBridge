import Foundation

enum DiagnosticLevel: String, Equatable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

struct DiagnosticEvent: Identifiable, Equatable {
    let id: Int
    let time: Date
    let level: DiagnosticLevel
    let message: String
}

struct DiagnosticsConfig: Equatable {
    var enabled = true
    var heartbeatInterval = 1.0
    var highLatencyMs = 150.0
    var lossWarningPct = 10.0
    var loggingEnabled = true
    var graphDuration = 60.0

    static func clampInterval(_ v: Double) -> Double { min(max(v.isFinite ? v : 1.0, 0.25), 2.0) }
    static func clampLatency(_ v: Double) -> Double { min(max(v.isFinite ? v : 150.0, 20.0), 1000.0) }
    static func clampLoss(_ v: Double) -> Double { min(max(v.isFinite ? v : 10.0, 1.0), 50.0) }
    static func clampDuration(_ v: Double) -> Double { min(max(v.isFinite ? v : 60.0, 30.0), 300.0) }

    mutating func validate() {
        heartbeatInterval = Self.clampInterval(heartbeatInterval)
        highLatencyMs = Self.clampLatency(highLatencyMs)
        lossWarningPct = Self.clampLoss(lossWarningPct)
        graphDuration = Self.clampDuration(graphDuration)
    }
}

enum ConnectionQuality: String, Equatable {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
    case unstable = "Unstable"
    case disconnected = "Disconnected"
}

struct LatencySample: Equatable {
    let time: TimeInterval
    let rttMs: Double?
    let missed: Bool
    let high: Bool
}

struct NetworkSnapshot: Equatable {
    let now: TimeInterval
    let status: String
    let quality: ConnectionQuality
    let connected: Bool
    let wanted: Bool
    let latencyMs: Double?
    let averageMs: Double?
    let minimumMs: Double?
    let maximumMs: Double?
    let jitterMs: Double?
    let lossPct: Double
    let packetsSent: Int
    let packetsReceived: Int
    let uptime: TimeInterval
    let lastResponseDate: Date?
    let peerHostname: String?
    let peerIP: String
    let protocolVersion: UInt8
    let reconnectionCount: Int
    let heartbeatSent: Int
    let heartbeatReplies: Int
    let heartbeatMisses: Int
    let protocolErrors: Int
    let samples: [LatencySample]
    let events: [DiagnosticEvent]
    let config: DiagnosticsConfig
}

private final class DiagnosticLog {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []
    private var nextID = 0
    private var throttles: [String: Date] = [:]
    private let limit = 250

    func log(_ level: DiagnosticLevel, _ message: String, key: String?, throttle: TimeInterval, enabled: Bool) {
        guard enabled else { return }
        let now = Date()
        lock.lock()
        if let key = key, let last = throttles[key], now.timeIntervalSince(last) < throttle {
            lock.unlock()
            return
        }
        if let key = key { throttles[key] = now }
        nextID += 1
        events.append(DiagnosticEvent(id: nextID, time: now, level: level, message: message))
        if events.count > limit { events.removeFirst(events.count - limit) }
        lock.unlock()
    }

    func snapshot() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func clear() {
        lock.lock()
        events.removeAll()
        throttles.removeAll()
        lock.unlock()
    }
}

final class NetworkDiagnostics {
    private let lock = NSLock()
    private let log = DiagnosticLog()
    private var config = DiagnosticsConfig()
    private var connected = false
    private var wanted = false
    private var connecting = false
    private var host = ""
    private var peerHostname: String?
    private var protocolVersion: UInt8 = 0
    private var sessionStart: TimeInterval = 0
    private var reconnectionCount = 0
    private var connectionAttempts = 0
    private var lastRttMs: Double?
    private var lastResponseDate: Date?
    private var samples: [LatencySample] = []
    private var packetsSent = 0
    private var packetsReceived = 0
    private var bytesSent = 0
    private var bytesReceived = 0
    private var heartbeatSent = 0
    private var heartbeatReplies = 0
    private var heartbeatMisses = 0
    private var consecutiveMisses = 0
    private var protocolErrors = 0
    private var lastHeartbeatAt: TimeInterval = 0
    private var pending: (seq: UInt16, at: TimeInterval)?
    private var nextSeq: UInt16 = 0
    private var quality: ConnectionQuality = .disconnected
    private var candidateQuality: ConnectionQuality = .disconnected
    private var candidateSince: TimeInterval = 0
    private var lastQualityEval: TimeInterval = 0
    private var lastJitter: Double = 0

    func currentConfig() -> DiagnosticsConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    func updateConfig(_ newValue: DiagnosticsConfig) {
        var v = newValue
        v.validate()
        lock.lock()
        let old = config
        config = v
        if v.graphDuration < old.graphDuration { pruneLocked(now: ProcessInfo.processInfo.systemUptime) }
        if old.enabled && !v.enabled {
            pending = nil
            lastHeartbeatAt = 0
            log.log(.info, "Network diagnostics disabled", key: "diag-enabled", throttle: 1, enabled: old.loggingEnabled)
        } else if !old.enabled && v.enabled {
            log.log(.info, "Network diagnostics enabled", key: "diag-enabled", throttle: 1, enabled: v.loggingEnabled)
        }
        lock.unlock()
    }

    func setWanted(_ value: Bool) {
        lock.lock()
        wanted = value
        if !value {
            connecting = false
            pending = nil
        }
        lock.unlock()
    }

    func noteAttempt(host: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        connectionAttempts += 1
        if connectionAttempts > 1 {
            reconnectionCount += 1
            connecting = true
        }
        self.host = host
        log.log(connectionAttempts > 1 ? .warning : .info,
                connectionAttempts > 1 ? "Reconnection attempt \(reconnectionCount) to \(host)"
                                       : "Connecting to \(host)",
                key: "attempt-\(host)", throttle: 2, enabled: config.loggingEnabled)
        lock.unlock()
        evaluateQuality(now: now)
    }

    func noteConnected(host: String, version: UInt8) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        connected = true
        connecting = false
        wanted = true
        self.host = host
        protocolVersion = version
        sessionStart = now
        peerHostname = nil
        consecutiveMisses = 0
        pending = nil
        lastHeartbeatAt = 0
        samples.append(LatencySample(time: now, rttMs: nil, missed: false, high: false))
        pruneLocked(now: now)
        log.log(.info, "Connection established (protocol \(version))", key: "connected", throttle: 1,
                enabled: config.loggingEnabled)
        if version < 4 {
            log.log(.info, "Heartbeat metrics require protocol 4; using the legacy keepalive",
                    key: "legacy-heartbeat", throttle: 1, enabled: config.loggingEnabled)
        }
        lock.unlock()
        evaluateQuality(now: now)
    }

    func noteDisconnected(_ reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard connected || connecting else { lock.unlock(); return }
        let wasConnected = connected
        connected = false
        connecting = false
        sessionStart = 0
        pending = nil
        samples.append(LatencySample(time: now, rttMs: nil, missed: false, high: false))
        pruneLocked(now: now)
        if wasConnected {
            log.log(.warning, "Connection lost: \(reason)", key: "disconnect-\(reason)", throttle: 3,
                    enabled: config.loggingEnabled)
        }
        quality = .disconnected
        candidateQuality = .disconnected
        candidateSince = now
        lock.unlock()
    }

    func noteConnectionFailure(_ reason: String) {
        lock.lock()
        connecting = true
        log.log(.warning, "Connection attempt failed: \(reason)", key: "failure-\(reason)", throttle: 5,
                enabled: config.loggingEnabled)
        lock.unlock()
    }

    func noteUserDisconnect() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let wasConnected = connected
        connected = false
        connecting = false
        wanted = false
        sessionStart = 0
        pending = nil
        samples.append(LatencySample(time: now, rttMs: nil, missed: false, high: false))
        pruneLocked(now: now)
        if wasConnected { log.log(.info, "Disconnected by user", key: "user-disconnect", throttle: 1, enabled: config.loggingEnabled) }
        quality = .disconnected
        candidateQuality = .disconnected
        candidateSince = now
        lock.unlock()
    }

    func noteHostname(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lock.lock()
        peerHostname = clean
        log.log(.debug, "Windows hostname: \(clean)", key: "hostname", throttle: 1, enabled: config.loggingEnabled)
        lock.unlock()
    }

    func noteSleep() {
        lock.lock()
        log.log(.info, "Mac went to sleep - diagnostics paused", key: "sleep", throttle: 1, enabled: config.loggingEnabled)
        lock.unlock()
    }

    func noteWake() {
        lock.lock()
        lastHeartbeatAt = 0
        log.log(.info, "Mac woke up - resuming diagnostics", key: "wake", throttle: 1, enabled: config.loggingEnabled)
        lock.unlock()
    }

    func noteProtocolError(_ detail: String) {
        lock.lock()
        protocolErrors += 1
        log.log(.error, "Protocol error: \(detail)", key: "proto-\(detail)", throttle: 5, enabled: config.loggingEnabled)
        lock.unlock()
    }

    func notePacketSent(bytes: Int) {
        lock.lock()
        packetsSent += 1
        bytesSent += bytes
        lock.unlock()
    }

    func noteFrameReceived(bytes: Int) {
        lock.lock()
        packetsReceived += 1
        bytesReceived += bytes
        lock.unlock()
    }

    func takeHeartbeatTick(now: TimeInterval) -> UInt16? {
        lock.lock()
        guard connected, config.enabled else { lock.unlock(); return nil }
        if let p = pending, now - p.at >= heartbeatTimeoutLocked() {
            pending = nil
            heartbeatMisses += 1
            consecutiveMisses += 1
            samples.append(LatencySample(time: now, rttMs: nil, missed: true, high: false))
            pruneLocked(now: now)
            log.log(.warning, "Heartbeat timeout (sequence \(p.seq))", key: "heartbeat-timeout", throttle: 2,
                    enabled: config.loggingEnabled)
        }
        guard pending == nil, now - lastHeartbeatAt >= config.heartbeatInterval else {
            lock.unlock()
            evaluateQuality(now: now)
            return nil
        }
        nextSeq = nextSeq &+ 1
        let seq = nextSeq
        pending = (seq, now)
        lastHeartbeatAt = now
        heartbeatSent += 1
        lock.unlock()
        evaluateQuality(now: now)
        return seq
    }

    func pendingHeartbeatSentAt(seq: UInt16) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = pending, p.seq == seq else { return nil }
        return p.at
    }

    func completeHeartbeat(seq: UInt16, rttMs: Double, now: TimeInterval) {
        lock.lock()
        guard let p = pending, p.seq == seq else { lock.unlock(); return }
        pending = nil
        consecutiveMisses = 0
        heartbeatReplies += 1
        lastRttMs = rttMs
        lastResponseDate = Date()
        let high = rttMs > config.highLatencyMs
        samples.append(LatencySample(time: now, rttMs: rttMs, missed: false, high: high))
        pruneLocked(now: now)
        if high {
            log.log(.warning, String(format: "Latency spike: %.1f ms", rttMs), key: "latency-spike", throttle: 10,
                    enabled: config.loggingEnabled)
        }
        let stats = statsLocked()
        if let j = stats.jitter, j > max(15, config.highLatencyMs * 0.35), j > lastJitter * 1.5 {
            log.log(.warning, String(format: "Jitter increased to %.1f ms", j), key: "jitter", throttle: 15,
                    enabled: config.loggingEnabled)
        }
        lastJitter = stats.jitter ?? 0
        let loss = stats.loss
        if loss >= config.lossWarningPct {
            log.log(.warning, String(format: "Heartbeat loss %.1f%% exceeds the %.1f%% warning threshold",
                                     loss, config.lossWarningPct),
                    key: "loss", throttle: 15, enabled: config.loggingEnabled)
        }
        lock.unlock()
        evaluateQuality(now: now)
    }

    func snapshot() -> NetworkSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let stats = statsLocked()
        let uptime = connected && sessionStart > 0 ? now - sessionStart : 0
        let result = NetworkSnapshot(
            now: now,
            status: connected ? "Connected" : (wanted ? "Reconnecting" : "Disconnected"),
            quality: quality,
            connected: connected,
            wanted: wanted,
            latencyMs: lastRttMs,
            averageMs: stats.average,
            minimumMs: stats.minimum,
            maximumMs: stats.maximum,
            jitterMs: stats.jitter,
            lossPct: stats.loss,
            packetsSent: packetsSent,
            packetsReceived: packetsReceived,
            uptime: uptime,
            lastResponseDate: lastResponseDate,
            peerHostname: peerHostname,
            peerIP: host,
            protocolVersion: protocolVersion,
            reconnectionCount: reconnectionCount,
            heartbeatSent: heartbeatSent,
            heartbeatReplies: heartbeatReplies,
            heartbeatMisses: heartbeatMisses,
            protocolErrors: protocolErrors,
            samples: samples,
            events: log.snapshot(),
            config: config
        )
        lock.unlock()
        return result
    }

    func clearLog() { log.clear() }

    func exportText() -> String {
        let s = snapshot()
        let f = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("MacKeyBridge Network Diagnostics")
        lines.append("Exported: \(f.string(from: Date()))")
        lines.append("")
        lines.append("Status: \(s.status)")
        lines.append("Quality: \(s.quality.rawValue)")
        lines.append("Windows host: \(s.peerHostname ?? "unknown")")
        lines.append("Windows address: \(s.peerIP.isEmpty ? "none" : s.peerIP)")
        lines.append("Protocol: \(s.protocolVersion == 0 ? "none" : "v\(s.protocolVersion)")")
        lines.append(String(format: "Latency: %@ ms (min %@ / max %@ / avg %@)",
                            format(s.latencyMs), format(s.minimumMs), format(s.maximumMs), format(s.averageMs)))
        let loss = s.heartbeatSent == 0 ? "—" : String(format: "%.1f%%", s.lossPct)
        lines.append("Jitter: \(format(s.jitterMs)) ms · heartbeat loss: \(loss)")
        lines.append("Frames sent: \(s.packetsSent) · frames received: \(s.packetsReceived)")
        lines.append(String(format: "Heartbeats: \(s.heartbeatSent) sent / \(s.heartbeatReplies) replied / \(s.heartbeatMisses) missed"))
        lines.append(String(format: "Uptime: \(formatDuration(s.uptime)) · reconnections: \(s.reconnectionCount)"))
        lines.append("")
        lines.append("Events:")
        if s.events.isEmpty {
            lines.append("  (none)")
        } else {
            for e in s.events {
                lines.append("  \(f.string(from: e.time)) [\(e.level.rawValue)] \(e.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func heartbeatTimeoutLocked() -> TimeInterval { max(2.5, config.heartbeatInterval * 3.0) }

    private func pruneLocked(now: TimeInterval) {
        samples.removeAll { now - $0.time > config.graphDuration }
        let maxSamples = 600
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }

    private func statsLocked() -> (average: Double?, minimum: Double?, maximum: Double?, jitter: Double?, loss: Double) {
        let values = samples.compactMap { $0.rttMs }.filter { $0.isFinite }
        let missed = samples.filter { $0.missed }.count
        let total = values.count + missed
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        var jitter: Double?
        if values.count >= 2 {
            var sum = 0.0
            for i in 1..<values.count { sum += abs(values[i] - values[i - 1]) }
            jitter = sum / Double(values.count - 1)
        }
        return (average, values.min(), values.max(), jitter, total == 0 ? 0 : Double(missed) / Double(total) * 100.0)
    }

    private func evaluateQuality(now: TimeInterval) {
        lock.lock()
        guard now - lastQualityEval >= 0.9 else { lock.unlock(); return }
        lastQualityEval = now
        let stats = statsLocked()
        var desired: ConnectionQuality
        if !connected {
            desired = .disconnected
        } else if consecutiveMisses >= 2 || stats.loss >= max(20, config.lossWarningPct * 2) {
            desired = .unstable
        } else if stats.loss >= config.lossWarningPct {
            desired = .poor
        } else if let a = stats.average, let j = stats.jitter {
            if a <= 30 && j <= 10 { desired = .excellent }
            else if a <= 80 && j <= 25 { desired = .good }
            else if a <= 150 && j <= 50 { desired = .fair }
            else { desired = .poor }
        } else {
            desired = .fair
        }
        if desired == quality {
            candidateQuality = desired
            candidateSince = now
        } else if desired == candidateQuality {
            if now - candidateSince >= 3.0 {
                quality = desired
                log.log(desired == .unstable || desired == .poor ? .warning : .info,
                        "Connection quality: \(desired.rawValue)", key: "quality", throttle: 3,
                        enabled: config.loggingEnabled)
            }
        } else {
            candidateQuality = desired
            candidateSince = now
        }
        lock.unlock()
    }

    private func format(_ v: Double?) -> String { v == nil ? "—" : String(format: "%.1f", v!) }
    private func formatDuration(_ v: TimeInterval) -> String {
        guard v > 0 else { return "0s" }
        let m = Int(v) / 60
        let s = Int(v) % 60
        return m == 0 ? "\(s)s" : "\(m)m \(s)s"
    }
}
