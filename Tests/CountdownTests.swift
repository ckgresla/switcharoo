import Foundation
@main struct CountdownTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 10000)
        var timer = CountdownState()
        timer.start(seconds: 60,now: now)
        assert(timer.remaining(at: now.addingTimeInterval(20)) == 40)
        timer.pause(now: now.addingTimeInterval(20))
        assert(timer.remaining(at: now.addingTimeInterval(200)) == 40)
        timer.resume(now: now.addingTimeInterval(200))
        assert(timer.remaining(at: now.addingTimeInterval(215)) == 25)
        let restored = try JSONDecoder().decode(CountdownState.self,from: JSONEncoder().encode(timer))
        assert(restored == timer && restored.remaining(at: now.addingTimeInterval(235)) == 5)
        assert(timer.tick(now: now.addingTimeInterval(250)))
        assert(!timer.tick(now: now.addingTimeInterval(251)))
        assert(timer.finished && timer.remaining(at: now.addingTimeInterval(250)) == 0)
        timer.reset(); assert(!timer.finished && !timer.running && timer.remaining(at: now) == 60)
        timer.start(seconds: .nan,now: now); assert(!timer.running)
        timer.start(seconds: 0,now: now); assert(!timer.running)
        timer.start(seconds: 86401,now: now); assert(!timer.running)
        timer.start(seconds: 1,now: now); assert(timer.running)
        var collection = CountdownCollection()
        let tea = collection.add(name: "Tea",seconds: 120,now: now)!
        let focus = collection.add(name: "Focus",seconds: 1500,now: now)!
        assert(tea != focus && collection.timers.count == 2)
        collection.update(tea) { $0.state.pause(now: now.addingTimeInterval(30)) }
        assert(collection.timers[0].state.remaining(at: now.addingTimeInterval(60)) == 90)
        assert(collection.timers[1].state.remaining(at: now.addingTimeInterval(60)) == 1440)
        collection.update(focus) { $0.name = "Reading" }
        assert(collection.timers[0].name == "Tea" && collection.timers[1].name == "Reading")
        let savedCollection = try JSONDecoder().decode(CountdownCollection.self,from: JSONEncoder().encode(collection))
        assert(savedCollection == collection)
        collection.update(tea) { $0.state.resume(now: now.addingTimeInterval(60)) }
        assert(collection.tick(now: now.addingTimeInterval(151)) == [tea])
        assert(collection.timers[1].state.running)
        assert(collection.tick(now: now.addingTimeInterval(152)).isEmpty)
        collection.remove(tea)
        assert(collection.timers.count == 1 && collection.timers[0].id == focus)
        assert(collection.add(name: "Invalid",seconds: 0,now: now) == nil)
        let duplicateName = collection.add(name: "Reading",seconds: 20,now: now)!
        assert(duplicateName != focus)
        collection.update(duplicateName) { $0.name = "" }
        assert(collection.timers[1].displayName == "Timer")
        print("Countdown: 24 checks passed (independent named timers, pause/resume, persistence, expiration, deletion, duration bounds).")
    }
}
