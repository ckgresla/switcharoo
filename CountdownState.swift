import Foundation

struct CountdownState: Codable, Equatable {
    var duration: TimeInterval = 25*60
    var deadline: Date?
    var pausedRemaining: TimeInterval?
    var finished = false
    func remaining(at date: Date) -> TimeInterval { max(0,deadline.map { $0.timeIntervalSince(date) } ?? pausedRemaining ?? (finished ? 0 : duration)) }
    var running: Bool { deadline != nil }
    mutating func start(seconds: TimeInterval,now: Date) {
        guard seconds.isFinite,seconds >= 1,seconds <= 86400 else { return }
        duration = seconds; deadline = now.addingTimeInterval(seconds); pausedRemaining = nil; finished = false
    }
    mutating func pause(now: Date) { guard running else { return }; pausedRemaining = remaining(at: now); deadline = nil; finished = pausedRemaining == 0 }
    mutating func resume(now: Date) { guard let remaining = pausedRemaining,remaining > 0 else { return }; deadline = now.addingTimeInterval(remaining); pausedRemaining = nil }
    mutating func reset() { deadline = nil; pausedRemaining = nil; finished = false }
    mutating func tick(now: Date) -> Bool {
        guard let deadline,deadline <= now else { return false }
        self.deadline = nil; pausedRemaining = nil; finished = true; return true
    }
}

struct NamedCountdown: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var state = CountdownState()
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Timer" : name }
}
struct CountdownCollection: Codable, Equatable {
    var timers: [NamedCountdown] = []
    @discardableResult mutating func add(name: String,seconds: TimeInterval,now: Date) -> UUID? {
        guard timers.count < 64,seconds.isFinite,(1...86400).contains(seconds) else { return nil }
        var timer = NamedCountdown(name: String(name.prefix(80)))
        timer.state.start(seconds: seconds,now: now); timers.append(timer); return timer.id
    }
    mutating func update(_ id: UUID,_ change: (inout NamedCountdown) -> Void) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }; change(&timers[index])
    }
    mutating func remove(_ id: UUID) { timers.removeAll { $0.id == id } }
    mutating func tick(now: Date) -> [UUID] {
        var finished: [UUID] = []
        for index in timers.indices { if timers[index].state.tick(now: now) { finished.append(timers[index].id) } }
        return finished
    }
}
