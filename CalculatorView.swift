import SwiftUI
import AppKit
import Combine

struct CalculatorAnswerView: View {
    @ObservedObject var model: CalculatorModel
    @Environment(\.colorScheme) private var scheme
    var openGraph: (() -> Void)?
    var replaceQuery: ((String) -> Void)?
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if let answer = model.answer {
                HStack(spacing:14) {
                    if let rgba = answer.rgba,rgba.count == 4 {
                        RoundedRectangle(cornerRadius:8).fill(Color(.sRGB,red:rgba[0],green:rgba[1],blue:rgba[2],opacity:rgba[3])).frame(width:44,height:44)
                            .overlay { RoundedRectangle(cornerRadius:8).strokeBorder(Color.primary.opacity(0.15)) }
                    }
                    Text(answer.value).font(SwitcharooTypography.ui(size:26)).lineLimit(2).textSelection(.enabled)
                }
                HStack {
                    Text(model.attribution ?? answer.kind).foregroundStyle(ToolStyle.secondary(scheme)).lineLimit(1)
                    Spacer()
                    if let openGraph { Button("Calculator",action:openGraph) }
                    Button("Copy") { model.copy() }.disabled(!model.canCopy)
                    Menu("Actions") {
                        Button("Copy Answer") { model.copy() }.keyboardShortcut(.return,modifiers:[])
                        Button("Copy Unformatted Answer") { model.copy(raw:true) }.keyboardShortcut(.return,modifiers:.command)
                        Button("Copy Question and Answer") { model.copy(includeQuery:true) }.keyboardShortcut(.return,modifiers:[.command,.shift])
                        Button("Copy Question") { model.copy(questionOnly:true) }
                        if let formats = answer.formats {
                            Divider()
                            ForEach(formats,id:\.name) { format in
                                Button("Copy " + format.name) { guard model.canCopy else { return }; model.save(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(format.value,forType:.string) }
                            }
                        }
                        if let replaceQuery {
                            Button("Use Answer as Input") { model.save(); replaceQuery(answer.raw) }
                            if let swap = answer.swap { Button("Swap Units") { model.save(); replaceQuery(swap) } }
                        }
                        Button("Pin Calculation") { model.save(); if let entry = CalculatorHistory.shared.entries.first(where:{$0.query == model.query}),!entry.pinned { CalculatorHistory.shared.togglePin(entry.id) } }
                        Divider()
                        if model.hasRates { Button("Refresh Rates") { model.refresh() } }
                        Button("History") { model.save(); LauncherController.shared.model.navigate(.calculatorHistory) }
                        Button("Settings") { LauncherController.shared.model.navigate(.calculatorSettings) }
                    }.menuStyle(.borderlessButton).fixedSize().disabled(!model.canCopy).keyboardShortcut("k",modifiers:.command)
                }.font(SwitcharooTypography.ui(size:12)).buttonStyle(LauncherHoverStyle())
            } else if let error = model.error {
                HStack { Text(error).foregroundStyle(.secondary); Spacer(); Button("Retry") { model.refresh() }.buttonStyle(LauncherHoverStyle()) }
            } else if model.hasRates { Text("Fetching rate…").foregroundStyle(.secondary) }
        }.frame(maxWidth:.infinity,minHeight:88,alignment:.leading).padding(20)
    }
}

struct CalculatorHistoryView: View {
    @ObservedObject private var history = CalculatorHistory.shared
    @StateObject private var calculator = CalculatorModel()
    @State private var search = ""
    @State private var selection: UUID?
    @FocusState private var focused: Bool
    private var entries: [CalculatorHistoryEntry] { history.search(search) }
    private func select(_ id: UUID?) {
        selection = id
        calculator.update(entries.first(where:{$0.id == id})?.query ?? "")
    }
    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex(where:{$0.id == selection}) ?? (delta > 0 ? -1 : 0)
        select(entries[(index+delta+entries.count)%entries.count].id)
    }
    private func reuse(_ query: String) {
        LauncherController.shared.model.query = query
        LauncherController.shared.model.navigate(.search)
    }
    var body: some View {
        VStack(spacing:0) {
            TextField("Search history…",text:$search).textFieldStyle(.plain).focused($focused)
                .font(SwitcharooTypography.ui(size:17)).padding(.horizontal,20).frame(height:48)
                .onChange(of:search) { _,_ in select(entries.first?.id) }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onSubmit { calculator.copy() }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing:2) {
                        ForEach(entries) { entry in
                            Button { select(entry.id) } label: {
                                HStack(spacing:12) {
                                    Image(systemName:entry.pinned ? "pin" : "clock").frame(width:18)
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(entry.query).lineLimit(1)
                                        Text(entry.answer.value).font(SwitcharooTypography.ui(size:12)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(selection == entry.id ? Color.primary.opacity(0.065) : .clear,in:RoundedRectangle(cornerRadius:10))
                            }.buttonStyle(LauncherHoverStyle()).id(entry.id).contextMenu {
                                Button("Use Question") { reuse(entry.query) }
                                Button(entry.pinned ? "Unpin" : "Pin") { history.togglePin(entry.id) }
                                Button("Delete") { history.delete(entry.id); select(entries.first?.id) }
                            }
                        }
                        if entries.isEmpty { Text("No calculations").foregroundStyle(.secondary).padding(20) }
                    }.padding(10)
                }.onChange(of:selection) { _,id in if let id { proxy.scrollTo(id) } }
            }
            if calculator.hasContent {
                Divider()
                CalculatorAnswerView(model:calculator,replaceQuery:reuse)
            }
            HStack {
                Button("Clear Unpinned") { history.clearUnpinned(); select(entries.first?.id) }
                Spacer()
                if let entry = entries.first(where:{$0.id == selection}) { Button("Use Question") { reuse(entry.query) } }
            }.font(SwitcharooTypography.ui(size:12)).buttonStyle(LauncherHoverStyle()).padding(16)
        }.onAppear { focused = true; select(entries.first?.id) }
    }
}

struct CalculatorSettingsView: View {
    @AppStorage("calculator.rem") private var rem = 16.0
    @AppStorage("calculator.automaticUnits") private var automaticUnits = true
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            Toggle("Automatic unit conversion",isOn:$automaticUnits)
            HStack {
                Text("Base REM size")
                Spacer()
                TextField("Pixels",value:$rem,format:.number).textFieldStyle(.roundedBorder).frame(width:72)
                    .onChange(of:rem) { _,value in rem = value.isFinite ? max(1,min(1000,value)) : 16 }
                Text("px").foregroundStyle(.secondary)
            }
            HStack { Text("Number format"); Spacer(); Text(Locale.current.identifier).foregroundStyle(.secondary) }
            HStack { Text("History retention"); Spacer(); Text("3 months · pinned kept").foregroundStyle(.secondary) }
            Spacer()
        }.font(SwitcharooTypography.ui(size:14)).padding(24)
    }
}

struct GraphExpression: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var enabled = true
}
final class CalculatorGraphModel: ObservableObject {
    @Published var expressions: [GraphExpression] = {
        guard let data = UserDefaults.standard.data(forKey:"calculator.expressions"),
              let saved = try? JSONDecoder().decode([GraphExpression].self,from:data), saved.count <= 6 else {
            return [GraphExpression(text:"y = sin(x)")]
        }
        return saved
    }() { didSet { if let data = try? JSONEncoder().encode(expressions) { UserDefaults.standard.set(data,forKey:"calculator.expressions") }; update() } }
    @Published var a = 1.0 { didSet { update() } }
    @Published private(set) var curves: [CalculatorCurve] = []
    @Published private(set) var error: String?
    @Published var center = CGPoint.zero
    @Published var span = CGSize(width:20,height:20)
    private var pending: DispatchWorkItem?
    private var evaluation: DispatchWorkItem?
    private var generation = 0
    var xmin: Double { center.x-span.width/2 }
    var xmax: Double { center.x+span.width/2 }
    func update() {
        generation += 1; let current = generation
        pending?.cancel(); evaluation?.cancel()
        let pending = DispatchWorkItem { [weak self] in
            guard let self,current == self.generation else { return }
            self.evaluation = CalculatorEngine.shared.evaluate(["mode":"graph","expressions":self.expressions.map { $0.enabled ? $0.text : "" },"xmin":self.xmin,"xmax":self.xmax,"a":self.a]) { [weak self] response in
                guard let self,current == self.generation else { return }
                self.curves = response.curves ?? []; self.error = response.error
            }
        }
        self.pending = pending; DispatchQueue.main.asyncAfter(deadline:.now()+0.1,execute:pending)
    }
    func zoom(_ scale: Double) {
        let width = span.width*scale
        guard width > 0.00001,width < 1e7 else { return }
        span = CGSize(width:width,height:span.height*scale); update()
    }
    func reset() { center = .zero; span = CGSize(width:20,height:20); update() }
}

struct CalculatorWorkspaceView: View {
    @StateObject private var calculator = CalculatorModel()
    @StateObject private var graph = CalculatorGraphModel()
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    init(initialQuery: String = "") { _query = State(initialValue:initialQuery) }
    private func update() { calculator.update(query) }
    private func copy() { calculator.copy() }
    var body: some View {
        VStack(spacing:0) {
            TextField("Calculate or convert…",text:$query).textFieldStyle(.plain)
                .font(SwitcharooTypography.ui(size:17)).padding(.horizontal,20).frame(height:48)
                .focused($focused).onSubmit(copy).onChange(of:query) { _,_ in update() }
            if calculator.hasContent { CalculatorAnswerView(model:calculator,replaceQuery:{ query = $0 }) }
            Divider()
            HStack(spacing:0) {
                VStack(alignment:.leading,spacing:0) {
                    ScrollView {
                        VStack(spacing:0) {
                            ForEach(Array(graph.expressions.enumerated()),id:\.element.id) { index,expression in
                                VStack(alignment:.leading,spacing:5) {
                                    HStack(spacing:8) {
                                        Button { graph.expressions[index].enabled.toggle() } label: {
                                            Text("\(index+1)").font(SwitcharooTypography.ui(size:11)).foregroundStyle(curveColor(index,scheme)).opacity(expression.enabled ? 1:0.3).frame(width:14,height:16)
                                        }.buttonStyle(LauncherHoverStyle()).accessibilityLabel(expression.enabled ? "Hide expression \(index+1)" : "Show expression \(index+1)")
                                        TextField("y =",text:Binding(get:{ graph.expressions.first { $0.id == expression.id }?.text ?? "" },set:{ text in if let i = graph.expressions.firstIndex(where:{ $0.id == expression.id }) { graph.expressions[i].text = text } })).textFieldStyle(.plain).font(SwitcharooTypography.ui(size:13)).accessibilityLabel("Expression \(index+1)")
                                        Button { graph.expressions.remove(at:index) } label: { Image(systemName:"xmark").font(.system(size:10)) }.buttonStyle(LauncherHoverStyle()).accessibilityLabel("Remove expression \(index+1)")
                                    }
                                    if index < graph.curves.count,let error = graph.curves[index].error {
                                        Text(error).font(SwitcharooTypography.ui(size:11)).foregroundStyle(.secondary)
                                    }
                                }.padding(12)
                                Divider()
                            }
                        }
                    }
                    Button { graph.expressions.append(GraphExpression(text:"")) } label: { Label("Expression",systemImage:"plus") }
                        .buttonStyle(LauncherHoverStyle()).font(SwitcharooTypography.ui(size:12)).padding(12).disabled(graph.expressions.count >= 6)
                    HStack { Text("a"); Spacer(); Text(graph.a,format:.number.precision(.fractionLength(1))) }.font(SwitcharooTypography.ui(size:12)).padding(.horizontal,12)
                    Slider(value:$graph.a,in:-5...5,step:0.1).accessibilityLabel("Parameter a").padding(12)
                }.frame(width:198)
                Divider()
                CalculatorPlot(model:graph)
            }
            if let error = graph.error { Text(error).font(SwitcharooTypography.ui(size:12)).foregroundStyle(.secondary).padding(8) }
        }.onAppear { focused = true; update(); graph.update() }.onDisappear { calculator.save() }
    }
}

private func curveColor(_ index: Int,_ scheme: ColorScheme) -> Color {
    return scheme == .dark ? .white : .black
}
private struct CalculatorPlot: View {
    @ObservedObject var model: CalculatorGraphModel
    @Environment(\.colorScheme) private var scheme
    @State private var dragStart: CGPoint?
    var body: some View {
        GeometryReader { geometry in
            Canvas { context,size in
                let xmin = model.xmin,xmax = model.xmax,ymin = model.center.y-model.span.height/2,ymax = model.center.y+model.span.height/2
                func px(_ x: Double) -> Double { (x-xmin)/(xmax-xmin)*size.width }
                func py(_ y: Double) -> Double { (ymax-y)/(ymax-ymin)*size.height }
                func ticks(_ range: Double) -> Double {
                    let base = pow(10,floor(log10(range/6)))
                    return [1.0,2,5,10].map { $0*base }.first { range/$0 <= 8 } ?? base*10
                }
                let sx = ticks(model.span.width),sy = ticks(model.span.height)
                for x in stride(from:ceil(xmin/sx)*sx,through:xmax,by:sx) {
                    var line = Path(); line.move(to:CGPoint(x:px(x),y:0)); line.addLine(to:CGPoint(x:px(x),y:size.height))
                    context.stroke(line,with:.color(.primary.opacity(abs(x)<sx*0.01 ? 0.25:0.08)),lineWidth:1)
                    if abs(x)>sx*0.01,px(x)>20,px(x)<size.width-20 {
                        context.draw(Text(x,format:.number.precision(.significantDigits(3))).font(SwitcharooTypography.ui(size:11)).foregroundColor(.secondary),at:CGPoint(x:px(x),y:min(size.height-12,max(12,py(0)+14))))
                    }
                }
                for y in stride(from:ceil(ymin/sy)*sy,through:ymax,by:sy) {
                    var line = Path(); line.move(to:CGPoint(x:0,y:py(y))); line.addLine(to:CGPoint(x:size.width,y:py(y)))
                    context.stroke(line,with:.color(.primary.opacity(abs(y)<sy*0.01 ? 0.25:0.08)),lineWidth:1)
                    if abs(y)>sy*0.01,py(y)>14,py(y)<size.height-14 {
                        context.draw(Text(y,format:.number.precision(.significantDigits(3))).font(SwitcharooTypography.ui(size:11)).foregroundColor(.secondary),at:CGPoint(x:min(size.width-20,max(20,px(0)+20)),y:py(y)))
                    }
                }
                context.draw(Text("x").font(SwitcharooTypography.ui(size:11)).foregroundColor(.secondary),at:CGPoint(x:size.width-10,y:min(size.height-12,max(12,py(0)-12))))
                context.draw(Text("y").font(SwitcharooTypography.ui(size:11)).foregroundColor(.secondary),at:CGPoint(x:min(size.width-12,max(12,px(0)+12)),y:12))
                context.clip(to:Path(CGRect(origin:.zero,size:size)))
                for (index,curve) in model.curves.enumerated() {
                    var path = Path(); var previous: CGPoint?
                    for sample in curve.points {
                        guard sample.count == 2,let x = sample[0],let y = sample[1],y.isFinite else { previous = nil; continue }
                        let point = CGPoint(x:px(x),y:py(y))
                        guard abs(point.y) < size.height*4 else { previous = nil; continue }
                        if let previous,abs(point.y-previous.y)<size.height*0.8 { path.addLine(to:point) } else { path.move(to:point) }
                        previous = point
                    }
                    let dashes: [[CGFloat]] = [[],[6,4],[2,3],[10,3,2,3],[12,5],[2,3,2,6]]
                    context.stroke(path,with:.color(curveColor(index,scheme)),style:StrokeStyle(lineWidth:2,dash:dashes[index % 6]))
                }
            }.contentShape(Rectangle()).gesture(DragGesture().onChanged { value in
                if dragStart == nil { dragStart = model.center }
                guard let start = dragStart else { return }
                model.center = CGPoint(x:start.x-value.translation.width/geometry.size.width*model.span.width,y:start.y+value.translation.height/geometry.size.height*model.span.height)
                model.update()
            }.onEnded { _ in dragStart = nil })
            .accessibilityLabel("Graph of calculator expressions. Drag to pan; use zoom controls to change range.")
            VStack(spacing:10) {
                Button { model.zoom(0.8) } label: { Image(systemName:"plus") }.accessibilityLabel("Zoom in")
                Button { model.zoom(1.25) } label: { Image(systemName:"minus") }.accessibilityLabel("Zoom out")
                Button { model.reset() } label: { Image(systemName:"arrow.counterclockwise") }.accessibilityLabel("Reset graph")
            }.buttonStyle(LauncherHoverStyle()).padding(10).background(ToolStyle.background(scheme),in:RoundedRectangle(cornerRadius:8)).padding(10).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing)
        }
    }
}
