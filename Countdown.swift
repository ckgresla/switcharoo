import AppKit
import SwiftUI
import UserNotifications

final class CountdownModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = CountdownModel()
    @Published private(set) var collection = CountdownCollection()
    @Published var now = Date()
    @Published var message = ""
    @Published var draftName = ""
    @Published var draftMinutes: Double = 25
    private var ticker: Timer?
    private var generations: [UUID:Int] = [:]
    private let preview: Bool
    var timers: [NamedCountdown] { collection.timers }
    init(preview: Bool = false) {
        self.preview = preview
        super.init()
        guard !preview else { return }
        if let data = UserDefaults.standard.data(forKey: "countdown.collection"),let saved = try? JSONDecoder().decode(CountdownCollection.self,from: data),saved.timers.count <= 64,Set(saved.timers.map(\.id)).count == saved.timers.count {
            collection.timers = saved.timers.filter { $0.state.duration.isFinite && (1...86400).contains($0.state.duration) }
        } else if let data = UserDefaults.standard.data(forKey: "countdown.state"),let saved = try? JSONDecoder().decode(CountdownState.self,from: data),saved.duration.isFinite,(1...86400).contains(saved.duration),saved.running || saved.pausedRemaining != nil || saved.finished {
            collection.timers = [.init(name: "Timer",state: saved)]
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["switcharoo.countdown"])
        _ = collection.tick(now: now); persist()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5,repeats: true) { [weak self] _ in
            guard let self else { return }; self.now = Date()
            if !self.collection.tick(now: self.now).isEmpty {
                self.persist()
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    if settings.authorizationStatus != .authorized { DispatchQueue.main.async { NSSound(named: "Glass")?.play() } }
                }
            }
        }
        for timer in timers where timer.state.running { schedule(timer.id,requestPermission: false) }
    }
    @discardableResult func add(name: String,minutes: Double) -> Bool {
        guard let id = collection.add(name: name,seconds: minutes*60,now: Date()) else { message = timers.count >= 64 ? "64-timer limit reached." : "Duration: 1 second–24 hours."; return false }
        now = Date(); message = ""; persist(); schedule(id,requestPermission: true); return true
    }
    func pause(_ id: UUID) { collection.update(id) { $0.state.pause(now: Date()) }; now = Date(); persist(); cancel(id) }
    func resume(_ id: UUID) { collection.update(id) { $0.state.resume(now: Date()) }; now = Date(); persist(); schedule(id,requestPermission: false) }
    func restart(_ id: UUID) { collection.update(id) { $0.state.start(seconds: $0.state.duration,now: Date()) }; now = Date(); persist(); schedule(id,requestPermission: false) }
    func remove(_ id: UUID) { collection.remove(id); persist(); cancel(id) }
    func rename(_ id: UUID,_ name: String) {
        collection.update(id) { $0.name = String(name.prefix(80)) }; persist()
        schedule(id,requestPermission: false)
    }
    private func persist() { guard !preview else { return }; if let data = try? JSONEncoder().encode(collection) { UserDefaults.standard.set(data,forKey: "countdown.collection") } }
    private func notificationID(_ id: UUID) -> String { "switcharoo.timer.\(id.uuidString)" }
    private func cancel(_ id: UUID) {
        generations[id,default: 0] += 1
        guard !preview else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID(id)])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationID(id)])
    }
    private func schedule(_ id: UUID,requestPermission: Bool) {
        cancel(id)
        guard !preview,let timer = timers.first(where: { $0.id == id }),let deadline = timer.state.deadline else { return }
        let generation = generations[id],center = UNUserNotificationCenter.current()
        let schedule: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self,self.generations[id] == generation,self.timers.contains(where: { $0.id == id && $0.state.deadline == deadline }),deadline > Date() else { return }
                let content = UNMutableNotificationContent(); content.title = timer.displayName; content.body = "Timer finished"; content.sound = .default
                let request = UNNotificationRequest(identifier: self.notificationID(id),content: content,trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1,deadline.timeIntervalSinceNow),repeats: false))
                center.add(request) { error in if let error { DispatchQueue.main.async { self.message = "Notification failed: \(error.localizedDescription)" } } }
            }
        }
        if requestPermission {
            center.requestAuthorization(options: [.alert,.sound]) { granted,_ in
                if granted { schedule() }
                else { DispatchQueue.main.async { self.message = "Notifications off · Sound only" } }
            }
        } else { center.getNotificationSettings { if $0.authorizationStatus == .authorized { schedule() } } }
    }
    static func sample() -> CountdownModel {
        let model = CountdownModel(preview: true),now = Date()
        _ = model.collection.add(name: "Focus",seconds: 25*60,now: now.addingTimeInterval(-7*60))
        _ = model.collection.add(name: "Tea",seconds: 5*60,now: now.addingTimeInterval(-2*60))
        if let id = model.collection.add(name: "Laundry",seconds: 45*60,now: now) { model.collection.update(id) { $0.state.pause(now: now) } }
        model.now = now; return model
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter,willPresent notification: UNNotification,withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner,.sound]) }
    func userNotificationCenter(_ center: UNUserNotificationCenter,didReceive response: UNNotificationResponse,withCompletionHandler completionHandler: @escaping () -> Void) { DispatchQueue.main.async { LauncherController.shared.show(.timers); completionHandler() } }
}

struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    var embedded = false
    @State private var query = ""
    @Environment(\.colorScheme) private var scheme
    private var filtered: [NamedCountdown] { model.timers.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !embedded { Text("Timers").font(SwitcharooTypography.ui(size: 14,weight: .medium)) }
                Spacer()
                TextField("Search timers",text: $query).textFieldStyle(.plain).frame(width: 180)
            }.padding(.leading,embedded ? 20 : 88).padding(.trailing,24).frame(height: embedded ? 44 : 52)
            Divider()
            HStack(spacing: 12) {
                TextField("Timer name",text: $model.draftName).textFieldStyle(.plain).onSubmit(add)
                TextField("Minutes",value: $model.draftMinutes,format: .number).textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 60).onSubmit(add)
                Text("min").foregroundStyle(ToolStyle.secondary(scheme))
                Button("Start") { add() }.buttonStyle(ToolButton(prominent: true))
            }.padding(20)
            HStack(spacing: 8) { ForEach([1,5,15,25,45,60],id: \.self) { value in
                Button("\(value)m") { model.draftMinutes = Double(value) }.buttonStyle(LauncherHoverStyle()).padding(.horizontal,11).padding(.vertical,6).background(model.draftMinutes == Double(value) ? Color.primary.opacity(0.08) : .clear,in: Capsule())
            }; Spacer() }.font(SwitcharooTypography.ui(size: 12)).foregroundStyle(ToolStyle.secondary(scheme)).padding(.horizontal,20).padding(.bottom,18)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { timer in timerRow(timer) }
                    if filtered.isEmpty { Text(query.isEmpty ? "No timers" : "No results").foregroundStyle(ToolStyle.secondary(scheme)).padding(.vertical,50) }
                }.padding(.horizontal,20)
            }
            if !model.message.isEmpty { Divider(); Text(model.message).font(SwitcharooTypography.ui(size: 11)).foregroundStyle(ToolStyle.secondary(scheme)).padding(12) }
        }.font(SwitcharooTypography.ui(size: 14)).frame(maxWidth: .infinity).background(ToolStyle.background(scheme)).tint(ToolStyle.accent(scheme))
    }
    private func add() { if model.add(name: model.draftName,minutes: model.draftMinutes) { model.draftName = "" } }
    private func timerRow(_ timer: NamedCountdown) -> some View {
        HStack(spacing: 18) {
            Image(systemName: timer.state.finished ? "checkmark.circle" : "timer").font(SwitcharooTypography.ui(size: 20,weight: .light)).foregroundStyle(ToolStyle.secondary(scheme)).frame(width: 30)
            VStack(alignment: .leading,spacing: 7) {
                TextField("Timer",text: Binding(get: { model.timers.first { $0.id == timer.id }?.name ?? timer.name },set: { model.rename(timer.id,$0) })).textFieldStyle(.plain).font(SwitcharooTypography.ui(size: 15,weight: .medium)).accessibilityLabel("Timer name")
                Text(timer.state.finished ? "Finished" : timer.state.running ? "Running" : "Paused").font(SwitcharooTypography.ui(size: 11)).foregroundStyle(ToolStyle.secondary(scheme))
            }
            Spacer(minLength: 10)
            Text(display(timer.state.remaining(at: model.now))).font(SwitcharooTypography.ui(size: embedded ? 24 : 28,weight: .light)).monospacedDigit().frame(minWidth: 100,alignment: .trailing)
            Button { if timer.state.finished { model.restart(timer.id) } else if timer.state.running { model.pause(timer.id) } else { model.resume(timer.id) } } label: {
                Image(systemName: timer.state.finished ? "arrow.counterclockwise" : timer.state.running ? "pause.fill" : "play.fill").frame(width: 28,height: 28)
            }.buttonStyle(LauncherHoverStyle()).help(timer.state.finished ? "Restart" : timer.state.running ? "Pause" : "Resume")
            Menu {
                Button("Restart") { model.restart(timer.id) }
                Button("Delete",role: .destructive) { model.remove(timer.id) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
        }.padding(.vertical,embedded ? 16 : 22).overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
    }
    private func display(_ value: TimeInterval) -> String {
        let remaining = Int(ceil(value))
        return remaining >= 3600 ? String(format: "%d:%02d:%02d",remaining/3600,(remaining/60)%60,remaining%60) : String(format: "%02d:%02d",remaining/60,remaining%60)
    }
}
