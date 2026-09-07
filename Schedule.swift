import AppKit
import SwiftUI
import EventKit

struct ScheduleCalendar: Identifiable {
    var id: String
    var title: String
    var color: CGColor
}
struct ScheduleEvent: Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var calendarID: String
    var calendar: String
    var color: CGColor
    var location: String
    var notes: String
    var meeting: URL?
}

final class ScheduleModel: ObservableObject {
    static let shared = ScheduleModel()
    @Published var query = ""
    @Published var selected: String?
    @Published var date = Calendar.current.startOfDay(for: Date())
    @Published private(set) var events: [ScheduleEvent] = []
    @Published private(set) var calendars: [ScheduleCalendar] = []
    @Published var selectedCalendars: Set<String> = []
    @Published private(set) var authorization = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var loading = false
    @Published var error = ""
    let isPreview: Bool
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "switcharoo.calendar",qos: .userInitiated)
    private var observer: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var generation = 0
    init(preview: Bool = false) {
        isPreview = preview
        guard !preview else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged,object: store,queue: .main) { [weak self] _ in self?.refresh() }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,object: nil,queue: .main) { [weak self] _ in self?.refresh() }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
    var canRead: Bool { authorization == .fullAccess || isPreview }
    var visibleEvents: [ScheduleEvent] { events.filter { selectedCalendars.contains($0.calendarID) } }
    func connect() {
        guard !isPreview else { return }
        error = ""; loading = true
        store.requestFullAccessToEvents { [weak self] _, error in
            DispatchQueue.main.async {
                self?.loading = false
                if let error { self?.error = error.localizedDescription }
                self?.refresh()
            }
        }
    }
    func moveDay(_ offset: Int) {
        if let value = Calendar.current.date(byAdding: .day,value: offset,to: date) { date = value }
    }
    func refresh() {
        guard !isPreview else { return }
        authorization = EKEventStore.authorizationStatus(for: .event)
        generation += 1; let currentGeneration = generation
        guard canRead else { events = []; calendars = []; selectedCalendars = []; loading = false; return }
        let start = Calendar.current.startOfDay(for: date)
        guard let end = Calendar.current.date(byAdding: .day,value: 8,to: start) else { return }
        loading = true
        queue.async { [weak self] in
            guard let self else { return }
            let calendars = self.store.calendars(for: .event)
            let items = calendars.map { ScheduleCalendar(id: $0.calendarIdentifier,title: $0.title,color: $0.cgColor) }
            let predicate = self.store.predicateForEvents(withStart: start,end: end,calendars: calendars)
            let events = self.store.events(matching: predicate).filter { $0.status != .canceled }.map { event in
                ScheduleEvent(id: (event.eventIdentifier ?? UUID().uuidString)+"-\(event.startDate.timeIntervalSince1970)",title: event.title ?? "Untitled event",start: event.startDate,end: event.endDate,allDay: event.isAllDay,calendarID: event.calendar.calendarIdentifier,calendar: event.calendar.title,color: event.calendar.cgColor,location: event.location ?? "",notes: event.notes ?? "",meeting: Self.meetingURL(url: event.url,text: [event.location,event.notes].compactMap { $0 }.joined(separator: "\n")))
            }.sorted { a,b in a.allDay != b.allDay ? a.allDay : a.start < b.start }
            DispatchQueue.main.async {
                guard self.generation == currentGeneration else { return }
                let oldIDs = Set(self.calendars.map(\.id))
                self.selectedCalendars.formUnion(Set(items.map(\.id)).subtracting(oldIDs))
                self.selectedCalendars.formIntersection(Set(items.map(\.id)))
                self.calendars = items; self.events = events; self.loading = false
            }
        }
    }
    static func meetingURL(url: URL?,text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let links = (url.map { [$0] } ?? []) + (detector?.matches(in: text,range: NSRange(text.startIndex...,in: text)).compactMap(\.url) ?? [])
        return links.first { link in
            guard ["https","http"].contains(link.scheme?.lowercased() ?? ""),let host = link.host?.lowercased() else { return false }
            return ["zoom.us","zoom.com","meet.google.com","teams.microsoft.com","teams.live.com","webex.com","whereby.com"].contains { host == $0 || host.hasSuffix("."+$0) }
        }
    }
    static func preview() -> ScheduleModel {
        let model = ScheduleModel(preview: true)
        let day = Calendar.current.startOfDay(for: Date())
        let sky = CGColor(red: 63/255,green: 120/255,blue: 181/255,alpha: 1)
        let mint = CGColor(red: 79/255,green: 138/255,blue: 103/255,alpha: 1)
        model.calendars = [.init(id: "work",title: "Work",color: sky),.init(id: "personal",title: "Personal",color: mint)]
        model.selectedCalendars = ["work","personal"]
        for (index,item) in [("Research catch-up",9.5,0.5,"work"),("Focus time",10.0,2.0,"work"),("Coffee with Alex",13.0,0.75,"personal"),("Design review",15.0,1.0,"work")].enumerated() {
            model.events.append(.init(id: "example-\(index)",title: item.0,start: day.addingTimeInterval(item.1*3600),end: day.addingTimeInterval((item.1+item.2)*3600),allDay: false,calendarID: item.3,calendar: item.3 == "work" ? "Work" : "Personal",color: item.3 == "work" ? sky : mint,location: index == 2 ? "Neighborhood café" : "",notes: "",meeting: nil))
        }
        model.events.append(.init(id:"example-tomorrow",title:"Morning walk",start:day.addingTimeInterval(33*3600),end:day.addingTimeInterval(34*3600),allDay:false,calendarID:"personal",calendar:"Personal",color:mint,location:"",notes:"",meeting:nil))
        model.events.append(.init(id:"example-later",title:"Project planning",start:day.addingTimeInterval(58*3600),end:day.addingTimeInterval(59*3600),allDay:false,calendarID:"work",calendar:"Work",color:sky,location:"",notes:"",meeting:nil))
        return model
    }
}

struct ScheduleView: View {
    @ObservedObject var model: ScheduleModel
    var embedded = false
    var onBack: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @FocusState private var searchFocused: Bool
    @State private var expandedID: String?
    @State private var choosingDate = false
    private var filtered: [ScheduleEvent] { model.visibleEvents.filter { model.query.isEmpty || ($0.title+" "+$0.location+" "+$0.calendar).localizedCaseInsensitiveContains(model.query) } }
    private var groups: [(date:Date,events:[ScheduleEvent])] {
        let first = Calendar.current.startOfDay(for:model.date)
        return Dictionary(grouping:filtered,by:{ max(first,Calendar.current.startOfDay(for:$0.start)) })
            .map { (date:$0.key,events:$0.value) }.sorted { $0.date < $1.date }
    }
    var body: some View {
        VStack(spacing:0) {
            header
            Divider()
            if model.canRead {
                TimelineView(.periodic(from:.now,by:60)) { context in summary(now:context.date) }
                Divider()
                agenda
                Divider()
                footer
            } else { permission }
        }.font(SwitcharooTypography.ui(size:14)).background(ToolStyle.background(scheme)).tint(ToolStyle.accent(scheme))
            .onAppear { model.refresh(); searchFocused = true; chooseInitialEvent() }
            .onChange(of:model.events.map(\.id)) { _,_ in chooseInitialEvent() }
            .onChange(of:model.date) { _,_ in expandedID = nil; model.selected = nil; model.refresh() }
            .onChange(of:model.query) { _,_ in expandedID = nil; model.selected = filtered.first?.id }
    }
    private var header: some View {
        HStack(spacing:12) {
            if let onBack { Button(action:onBack) { Image(systemName:"arrow.left").frame(width:28,height:30) }.help("Back · Esc") }
            TextField("Filter schedule…",text:$model.query).textFieldStyle(.plain).font(SwitcharooTypography.ui(size:17)).focused($searchFocused)
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onSubmit { if let id = model.selected { expandedID = expandedID == id ? nil : id } }
            if model.loading { ProgressView().controlSize(.small) }
            Button { choosingDate.toggle() } label: { Image(systemName:"calendar").frame(width:28,height:30) }.help("Choose date")
                .popover(isPresented:$choosingDate) {
                    DatePicker("Date",selection:$model.date,displayedComponents:.date).datePickerStyle(.graphical).labelsHidden().padding(12)
                }
            Menu {
                Button("Refresh") { model.refresh() }.keyboardShortcut("r",modifiers:.command)
                Divider()
                ForEach(model.calendars) { calendar in
                    Toggle(isOn:Binding(get:{ model.selectedCalendars.contains(calendar.id) },set:{ if $0 { model.selectedCalendars.insert(calendar.id) } else { model.selectedCalendars.remove(calendar.id) }; chooseInitialEvent() })) {
                        Label { Text(calendar.title) } icon: { Circle().fill(Color(cgColor:calendar.color)).frame(width:8,height:8) }
                    }
                }
                Divider()
                Button("Open Calendar") { openCalendar() }
            } label: { Image(systemName:"ellipsis").frame(width:20,height:30) }.menuStyle(.borderlessButton).fixedSize().help("Calendars and actions")
        }.buttonStyle(LauncherHoverStyle(horizontal:3,vertical:2)).padding(.leading,embedded ? 18 : 88).padding(.trailing,22).frame(height:50)
    }
    private func summary(now: Date) -> some View {
        let dayEvents = model.visibleEvents.filter { Calendar.current.isDate($0.start,inSameDayAs:model.date) }
        let remaining = dayEvents.filter { !$0.allDay && $0.end > now }.count
        let next = model.visibleEvents.first { !$0.allDay && $0.end > max(now,model.date) }
        return HStack(alignment:.top,spacing:24) {
            VStack(alignment:.leading,spacing:7) {
                HStack(spacing:6) {
                    Text(dayName(model.date)).font(SwitcharooTypography.ui(size:14,weight:.medium))
                    Text(model.date.formatted(.dateTime.month(.abbreviated).day())).foregroundStyle(.secondary)
                    Spacer(minLength:4)
                    Button { model.moveDay(-1) } label: { Image(systemName:"chevron.left").frame(width:22,height:20) }.help("Previous day").keyboardShortcut(.leftArrow,modifiers:.command)
                    Button("Today") { model.date = Calendar.current.startOfDay(for:Date()) }.keyboardShortcut("t",modifiers:.command)
                    Button { model.moveDay(1) } label: { Image(systemName:"chevron.right").frame(width:22,height:20) }.help("Next day").keyboardShortcut(.rightArrow,modifiers:.command)
                }.font(SwitcharooTypography.ui(size:12)).buttonStyle(LauncherHoverStyle(horizontal:2,vertical:2))
                Text("\(dayEvents.count) event\(dayEvents.count == 1 ? "" : "s"), \(remaining) upcoming").font(SwitcharooTypography.ui(size:12)).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
            VStack(alignment:.leading,spacing:7) {
                HStack {
                    Text(next.map { $0.start <= now ? "Now" : "Next up" } ?? "Next up").foregroundStyle(.secondary)
                    Spacer()
                    if let next { Text((Calendar.current.isDateInToday(next.start) ? "" : dayName(next.start)+" · ")+next.start.formatted(date:.omitted,time:.shortened)).foregroundStyle(.secondary) }
                }.font(SwitcharooTypography.ui(size:12))
                Text(next?.title ?? "Nothing upcoming").font(SwitcharooTypography.ui(size:13,weight:.medium)).lineLimit(1)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.padding(.horizontal,24).padding(.vertical,18)
    }
    private var agenda: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    ForEach(groups,id:\.date) { group in
                        VStack(alignment:.leading,spacing:6) {
                            HStack(spacing:10) {
                                Text(dayName(group.date)).font(SwitcharooTypography.ui(size:12,weight:.medium))
                                Text(group.date.formatted(.dateTime.month(.abbreviated).day())).font(SwitcharooTypography.ui(size:12))
                            }.foregroundStyle(.secondary).padding(.horizontal,14).frame(height:24)
                            ForEach(group.events) { event in eventRow(event) }
                        }
                    }
                    if filtered.isEmpty { Text(model.query.isEmpty ? "Nothing scheduled" : "No matching events").foregroundStyle(.secondary).padding(20) }
                    if !model.error.isEmpty { Text(model.error).foregroundStyle(.secondary).padding(14) }
                }.padding(.horizontal,12)
            }.padding(.vertical,12)
                .onChange(of:model.selected) { _,id in if let id { proxy.scrollTo(id) } }
        }
    }
    private func eventRow(_ event: ScheduleEvent) -> some View {
        let past = event.end < Date()
        return VStack(alignment:.leading,spacing:0) {
            Button {
                model.selected = event.id
                expandedID = expandedID == event.id ? nil : event.id
            } label: {
                HStack(spacing:12) {
                    Circle().strokeBorder(Color(cgColor:event.color),lineWidth:1.8).frame(width:14,height:14)
                    Text(event.allDay ? "All day" : event.start.formatted(date:.omitted,time:.shortened)+" – "+event.end.formatted(date:.omitted,time:.shortened))
                        .font(SwitcharooTypography.ui(size:12)).monospacedDigit().frame(width:142,alignment:.leading)
                    Text(event.title).font(SwitcharooTypography.ui(size:14)).lineLimit(1)
                    Spacer(minLength:4)
                    if event.meeting != nil { Image(systemName:"video").font(SwitcharooTypography.ui(size:12)).foregroundStyle(.secondary) }
                    if expandedID == event.id { Image(systemName:"chevron.up").font(SwitcharooTypography.ui(size:10)).foregroundStyle(.secondary) }
                }.foregroundStyle(past ? Color.secondary : Color.primary).opacity(past ? 0.7 : 1)
                    .padding(.horizontal,14).frame(height:42).contentShape(Rectangle())
                    .background(model.selected == event.id ? Color.primary.opacity(0.065) : .clear,in:RoundedRectangle(cornerRadius:10))
            }.buttonStyle(LauncherHoverStyle(radius:10))
            if expandedID == event.id {
                VStack(alignment:.leading,spacing:10) {
                    Text(event.calendar).foregroundStyle(.secondary)
                    if !event.location.isEmpty { Label(event.location,systemImage:"mappin.and.ellipse").textSelection(.enabled) }
                    if !event.notes.isEmpty { Text(event.notes).textSelection(.enabled) }
                    HStack(spacing:16) {
                        if let link = event.meeting { Button("Join meeting") { NSWorkspace.shared.open(link) } }
                        Button("Open in Calendar") { openCalendar(event) }
                        Button("Copy details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString([event.title,event.start.formatted()+" – "+event.end.formatted(),event.calendar,event.location,event.meeting?.absoluteString ?? "",event.notes].filter { !$0.isEmpty }.joined(separator:"\n"),forType:.string)
                        }
                    }.buttonStyle(LauncherHoverStyle(horizontal:4,vertical:4))
                }.font(SwitcharooTypography.ui(size:12)).padding(.leading,40).padding(.trailing,18).padding(.top,8).padding(.bottom,16)
            }
        }.id(event.id)
    }
    private var footer: some View {
        HStack(spacing:12) {
            Image(systemName:"calendar").foregroundStyle(.secondary)
            Text(model.isPreview ? "Example schedule" : "My Schedule").foregroundStyle(.secondary)
            Spacer()
            if let selected = filtered.first(where:{$0.id == model.selected}) {
                Button("Open in Calendar") { openCalendar(selected) }
                Menu("Actions") {
                    Button(expandedID == selected.id ? "Hide Details" : "Show Details") { expandedID = expandedID == selected.id ? nil : selected.id }
                    if let link = selected.meeting { Button("Join Meeting") { NSWorkspace.shared.open(link) } }
                    Button("Copy Title") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.title,forType:.string) }
                }.menuStyle(.borderlessButton).fixedSize().keyboardShortcut("k",modifiers:.command)
            }
        }.font(SwitcharooTypography.ui(size:12)).buttonStyle(LauncherHoverStyle(horizontal:5,vertical:5)).padding(.horizontal,22).frame(height:42)
    }
    private var permission: some View {
        VStack(spacing:18) {
            Spacer()
            Image(systemName:"calendar").font(SwitcharooTypography.ui(size:28,weight:.light)).foregroundStyle(.secondary)
            if model.authorization == .denied || model.authorization == .restricted {
                Button("Open Calendar permissions") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }.buttonStyle(ToolButton(prominent:true))
            } else { Button("Connect calendars") { model.connect() }.buttonStyle(ToolButton(prominent:true)).disabled(model.loading) }
            if !model.error.isEmpty { Text(model.error).font(SwitcharooTypography.ui(size:12)).foregroundStyle(.secondary) }
            Spacer()
        }.padding(30).frame(maxWidth:.infinity)
    }
    private func dayName(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide))
    }
    private func chooseInitialEvent() {
        if !filtered.contains(where:{$0.id == model.selected}) {
            model.selected = filtered.first(where:{$0.end > Date() && !$0.allDay})?.id ?? filtered.first?.id
        }
    }
    private func moveSelection(_ delta: Int) {
        let ordered = groups.flatMap(\.events)
        guard !ordered.isEmpty else { return }
        let index = ordered.firstIndex(where:{$0.id == model.selected}) ?? (delta > 0 ? -1 : 0)
        model.selected = ordered[(index+delta+ordered.count)%ordered.count].id
        expandedID = nil
    }
    private func openCalendar(_ event: ScheduleEvent? = nil) { NSWorkspace.shared.open(URL(string:"calshow:\((event?.start ?? model.date).timeIntervalSinceReferenceDate)")!) }
}
