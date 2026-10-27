import SwiftUI
import Charts

private struct SimulationSetting: Identifiable { let id: String }

struct PipelineSimulatorView: View {
    @EnvironmentObject private var engine: TranslatorEngine
    @Environment(\.dismiss) private var dismiss
    @State private var options: [String:String] = [:]
    @State private var input = SimulationInput()
    @State private var result = SimulationResult()
    @State private var panel = "pipeline"
    @State private var cursor = 0
    @State private var playing = false
    @State private var loaded = false
    @State private var editing: SimulationSetting?
    @State private var scenario = "Clear subtitles"
    private let scenarios = ["Clear subtitles","Small fading text","Scrolling lyrics","Duplicate copies","New candidate overtakes work","Missing language pack","Session cache hit","Language switch","Repeated rotation evidence"]
    private var allKeys: [String] { TranslatorEngine.settingKeys.sorted() }
    private var extraKeys: [String] {
        let described = Set(PipelineSimulation.optionGroups.flatMap { $0.1 })
        return allKeys.filter { !described.contains($0) }
    }
    var body: some View {
        List {
            Section {
                Text("Decision simulation · not a device benchmark").font(.headline)
                Text("A private settings copy drives the same policy helpers as the live pipeline. OCR quality, processing costs and model output are assumptions; the sample's language classifier runs locally. No capture, downloads, translation calls, history writes, speech or clipboard actions occur.")
                    .font(.footnote).foregroundStyle(.secondary)
                Picker("Panel", selection: $panel) {
                    Text("Pipeline").tag("pipeline")
                    Text("Scenario").tag("scenario")
                    Text("Settings").tag("settings")
                }.pickerStyle(.segmented)
            }
            if panel == "pipeline" { pipelinePanel }
            if panel == "scenario" { scenarioPanel }
            if panel == "settings" { settingsPanel }
        }
        .settingsPage("Pipeline simulator")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        .onAppear { if !loaded { loaded = true; copyCurrentSettings() } }
        .onChange(of: options) { _, _ in rebuild() }
        .onChange(of: input) { _, _ in rebuild() }
        .task(id: playing) {
            guard playing else { return }
            while !Task.isCancelled && cursor < result.steps.count-1 {
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
                guard !Task.isCancelled else { return }
                cursor += 1
            }
            playing = false
        }
        .sheet(item: $editing) { setting in
            NavigationStack {
                SimulatorSettingEditor(key: setting.id, value: Binding(get: { options[setting.id] ?? "" }, set: { options[setting.id] = $0 }),
                    isBoolean: TranslatorEngine.defaults[setting.id] is Bool, choices: choices(for: setting.id))
            }
        }
    }
    private var pipelinePanel: some View {
        Group {
            Section("Virtual playback") {
                HStack {
                    Button { playing.toggle() } label: { Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") }
                    Spacer()
                    Button { playing = false; cursor = max(0,cursor-1) } label: { Image(systemName:"backward.end.fill") }.accessibilityLabel("Previous stage")
                    Button { playing = false; cursor = min(max(0,result.steps.count-1),cursor+1) } label: { Image(systemName:"forward.end.fill") }.accessibilityLabel("Next stage")
                    Button { playing = false; cursor = 0 } label: { Image(systemName:"arrow.counterclockwise") }.accessibilityLabel("Restart simulation")
                }.buttonStyle(.borderless)
                if result.steps.count > 1 {
                    Slider(value: Binding(get:{Double(cursor)},set:{playing=false;cursor=Int($0)}),in:0...Double(result.steps.count-1),step:1)
                }
                if let step = result.steps.first(where: { $0.id == cursor }) {
                    Text("\(step.id+1)/\(result.steps.count) · \(step.title)").font(.headline)
                    Text("\(step.lane) · \(step.state)").font(.subheadline).foregroundStyle(Theme.accent.start)
                    Text(step.detail).font(.footnote)
                    if !step.settings.isEmpty {
                        DisclosureGroup("Settings at this stage") { ForEach(step.settings,id:\.self) { settingRow($0) } }
                    }
                }
            }
            Section("Modeled timing · milliseconds") {
                Text(input.baseline).font(.caption).foregroundStyle(.secondary)
                if !result.lanes.isEmpty {
                    Chart(result.lanes) { lane in
                        BarMark(xStart:.value("Start ms",lane.start),xEnd:.value("End ms",max(lane.start+0.1,lane.end)),y:.value("Lane",lane.id))
                            .foregroundStyle(by:.value("Work",lane.role))
                    }
                    .chartXScale(domain:0...max(1,result.totalMs))
                    .chartXAxisLabel("Virtual elapsed time (ms)")
                    .frame(height:240)
                    LabeledContent("Modeled frame enqueue", value:"\(Int(result.totalMs)) ms")
                } else { Text("This scenario stops before a new PiP frame is enqueued.").font(.footnote) }
                Text("Stage means from a diagnostic export are input assumptions, not a replay of the original intervals or a prediction of the new version. Confirmation and speculative model work may overlap. Physical screen presentation is unmeasured.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Complete decision path") {
                ForEach(result.steps) { step in
                    Button {
                        cursor = step.id; playing = false
                    } label: {
                        HStack(alignment:.top,spacing:12) {
                            Image(systemName:step.id<cursor ? "checkmark.circle.fill" : (step.id==cursor ? "arrowtriangle.right.circle.fill" : "circle"))
                                .foregroundStyle(step.id==cursor ? Theme.accent.start : .secondary)
                            VStack(alignment:.leading,spacing:3) {
                                Text(step.title).font(.subheadline.weight(.semibold))
                                Text("\(step.lane) · \(step.state)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength:0)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Section("PiP result preview") {
                if result.displayAccepted {
                    VStack(alignment:horizontalAlignment,spacing:10) {
                        if PipelineSimulation.bool(options,"showOriginal") { Text(input.text).font(.caption).foregroundStyle(.secondary) }
                        Text(result.output).font(.headline).multilineTextAlignment(textAlignment)
                    }
                    .frame(maxWidth:.infinity,alignment:alignment)
                    .padding(max(8,min(40,PipelineSimulation.number(options,"pipPadding",24))))
                    .background(Theme.card,in:RoundedRectangle(cornerRadius:16))
                    Text("Illustrative caption placeholder. The real PiP renderer applies your complete font/theme/weight/scale settings; the inspector lists their values. No translated wording is generated here.").font(.caption).foregroundStyle(.secondary)
                } else { Text("No replacement caption: follow the stopped or rejected stage above.").font(.footnote) }
            }
        }
    }
    private var horizontalAlignment: HorizontalAlignment {
        switch options["pipAlignment"] { case "center": return .center; case "right":return .trailing; default:return .leading }
    }
    private var alignment: Alignment {
        switch options["pipAlignment"] { case "center": return .center; case "right":return .trailing; default:return .leading }
    }
    private var textAlignment: TextAlignment {
        switch options["pipAlignment"] { case "center":return .center;case "right":return .trailing;default:return .leading }
    }
    private var scenarioPanel: some View {
        Group {
            Section("Subtitle scenario") {
                Picker("Scenario",selection:$scenario) { ForEach(scenarios,id:\.self) { Text($0).tag($0) } }
                    .onChange(of:scenario) { _, _ in applyScenario() }
                TextEditor(text:$input.text).frame(minHeight:95).font(.body)
                LabeledContent("Assumed OCR confidence",value:"\(Int(input.confidence*100))%")
                Slider(value:$input.confidence,in:0.1...1,step:0.01)
                LabeledContent("Text box height",value:String(format:"%.3f",input.height))
                Slider(value:$input.height,in:0.005...0.1,step:0.005)
                LabeledContent("Bottom row position (y)",value:String(format:"%.2f",input.y))
                Slider(value:$input.y,in:0.02...0.85,step:0.01)
                LabeledContent("Frame difference",value:String(format:"%.1f",input.motion))
                Slider(value:$input.motion,in:0...20,step:0.5)
                Stepper("Consecutive empty reads · \(input.emptyReads)",value:$input.emptyReads,in:0...12)
                Stepper("Unchanged text · \(Int(input.unchangedSeconds)) s",value:$input.unchangedSeconds,in:0...20)
                Toggle("Duplicate caption copies",isOn:$input.duplicateCopies)
                Toggle("New unconfirmed candidate overtakes work",isOn:$input.superseded)
            }
            Section("Translation and device state") {
                Picker("Cache result",selection:$input.cacheOrigin) { ForEach(["fresh","session","saved","speculative"],id:\.self) { Text($0.capitalized).tag($0) } }
                Picker("Thermal state",selection:$input.thermal) { ForEach(["nominal","fair","serious","critical"],id:\.self) { Text($0.capitalized).tag($0) } }
                Toggle("Low Power Mode",isOn:$input.lowPower)
                Toggle("Language packs ready",isOn:$input.packReady)
                Toggle("Language pair supported",isOn:$input.pairSupported)
                Toggle("Capture paused",isOn:$input.paused)
                Toggle("Output frozen",isOn:$input.frozen)
                TextField("Prior source code (optional)",text:$input.priorSource).textInputAutocapitalization(.never)
                TextField("Prior confident source text (optional)",text:$input.priorText)
                Toggle("Automatic orientation already settled",isOn:$input.rotationSettled)
                Stepper("Previous rotation probes · \(input.rotationProbes)",value:$input.rotationProbes,in:0...4)
                LabeledContent("Reading-order vote",value:String(format:"%.1f",input.rotationVote))
                Slider(value:$input.rotationVote,in:-12...12,step:1)
            }
            Section("Editable timing assumptions") {
                timingField("OCR pass (ms)",$input.ocrMs)
                timingField("Translation model (ms)",$input.translationMs)
                timingField("Queue wait (ms)",$input.queueMs)
                timingField("Delivery/filtering (ms)",$input.transferMs)
                timingField("Frame preparation (ms)",$input.renderMs)
                Button("Use current app timing values") { useCurrentTiming() }
                Button("Use 16:11 paired-stage averages") {
                    input.ocrMs=104.65;input.translationMs=148.94;input.queueMs=205.43;input.transferMs=3.03;input.renderMs=1.64
                    input.baseline="94 paired outputs · 27 Oct 16:11 · v1.2.1; values become simulation assumptions"
                }
            }
        }
    }
    private func timingField(_ title:String,_ value:Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title,value:value,format:.number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth:105) }
    }
    private var settingsPanel: some View {
        Group {
            Section {
                Button("Copy current app settings into simulator") { copyCurrentSettings() }
                Text("\(allKeys.count) app settings are available below. All edits stay in this simulator; interface/workspace-only settings are identified separately from live pipeline decisions.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(PipelineSimulation.optionGroups,id:\.0) { group in
                Section { DisclosureGroup(group.0) { ForEach(group.1,id:\.self) { settingRow($0) } } }
            }
            Section { DisclosureGroup("Other interface & workspace settings") { ForEach(extraKeys,id:\.self) { settingRow($0) } } }
        }
    }
    private func settingRow(_ key:String) -> some View {
        Button { editing=SimulationSetting(id:key) } label: {
            VStack(alignment:.leading,spacing:3) {
                HStack { Text(key).font(.subheadline);Spacer();Text(options[key] ?? "default").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(PipelineSimulation.effect(for:key)).font(.caption2).foregroundStyle(.secondary)
            }
        }.buttonStyle(.plain)
    }
    private func copyCurrentSettings() {
        var snapshot:[String:String]=[:]
        for key in allKeys {
            let value=UserDefaults.standard.object(forKey:key) ?? TranslatorEngine.defaults[key]
            if TranslatorEngine.defaults[key] is Bool { snapshot[key]=((value as? Bool) ?? false) ? "true" : "false" }
            else if let value { snapshot[key]=String(describing:value) }
        }
        snapshot["source"]=engine.sourceCode;snapshot["target"]=engine.targetCode
        options=snapshot; rebuild()
    }
    private func useCurrentTiming() {
        let samples=engine.diag.pipeline
        if !samples.isEmpty {
            func mean(_ key:KeyPath<LatencyBreakdown,Double>)->Double { samples.reduce(0){$0+$1.stages[keyPath:key]}/Double(samples.count) }
            input.ocrMs=mean(\.recognition);input.translationMs=mean(\.translation);input.queueMs=mean(\.queue);input.transferMs=mean(\.delivery);input.renderMs=mean(\.rendering)
            input.baseline="\(samples.count) current app paired timing samples · used as simulation assumptions"
        } else {
            input.ocrMs=engine.ocrMs;input.translationMs=engine.translateMs;input.queueMs=engine.latency.last.queue;input.transferMs=engine.latency.last.delivery;input.renderMs=engine.latency.last.rendering
            input.baseline="Latest app values (zero means unavailable) · used as simulation assumptions"
        }
    }
    private func rebuild() { playing=false;cursor=0;result=PipelineSimulation.run(options:options,input:input) }
    private func applyScenario() {
        var value=SimulationInput()
        switch scenario {
        case "Small fading text": value.confidence=0.68;value.height=0.015;value.motion=10;value.emptyReads=2
        case "Scrolling lyrics":value.text="Eu vejo a luz\nO mundo vai mudar\nEu vejo a luz\nE volto a sonhar";value.height=0.035
        case "Duplicate copies":value.duplicateCopies=true
        case "New candidate overtakes work":value.superseded=true;value.queueMs=400;value.translationMs=600
        case "Missing language pack":value.packReady=false
        case "Session cache hit":value.cacheOrigin="session"
        case "Language switch":value.priorSource="pt";value.priorText="Olá meu amigo, como você está hoje?";value.text="안녕하세요, 오늘은 날씨가 아주 좋습니다.";options["source"]="auto"
        case "Repeated rotation evidence":value.rotationSettled=false;value.rotationProbes=3;value.rotationVote = -9
        default:break
        }
        input=value
    }
    private func choices(for key:String)->[String] {
        switch key {
        case "source":return ["auto"]+engine.languages.map(\.code)
        case "target":return engine.languages.map(\.code)
        case "speed":return SpeedPreset.allCases.map(\.rawValue)
        case "mode":return TranslateMode.allCases.map(\.rawValue)
        case "area":return OCRArea.allCases.map(\.rawValue)
        case "frameRot":return ["auto","0","90","180","270"]
        case "stability":return ["1","2","3"]
        case "displayPolicy":return ["immediate","readable"]
        case "pipAlignment":return ["left","center","right"]
        case "winSize":return WindowSize.allCases.map(\.rawValue)
        default:return []
        }
    }
}

private struct SimulatorSettingEditor: View {
    let key:String
    @Binding var value:String
    let isBoolean:Bool
    let choices:[String]
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        Form {
            Section(PipelineSimulation.effect(for:key)) {
                if isBoolean { Toggle(key,isOn:Binding(get:{value=="true" || value=="1"},set:{value=$0 ? "true" : "false"})) }
                else if !choices.isEmpty { Picker(key,selection:$value) { ForEach(choices,id:\.self){Text($0).tag($0)} } }
                else { TextEditor(text:$value).frame(minHeight:100).font(.body.monospaced()) }
                Text("Simulator only. Numeric values follow policy clamps; unsupported text values use the simulator's documented defaults. Rendering and interface preferences are inspected, not used to invent OCR/model timing benefits.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(key).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.topBarTrailing){Button("Done"){dismiss()}} }
    }
}
