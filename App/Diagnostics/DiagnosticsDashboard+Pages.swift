import SwiftUI
import Charts

extension DiagnosticsBody {
    var memoryPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Translation memory").font(.headline)
            LabeledContent("Entries", value: String(diag.memoryHealth.totalEntries))
            LabeledContent("Ready / needs validation", value: "\(diag.memoryHealth.readyEntries) / \(diag.memoryHealth.needsValidation)")
            LabeledContent("Conflicts", value: String(diag.memoryHealth.conflicts))
            LabeledContent("Database", value: ByteCountFormatter.string(fromByteCount: diag.memoryHealth.databaseBytes, countStyle: .file))
            LabeledContent("RAM entries", value: String(diag.memoryHealth.ramEntries))
            LabeledContent("Schema", value: String(diag.memoryHealth.schemaVersion))
            LabeledContent("Migration", value: diag.memoryHealth.migrationStatus)
            LabeledContent("Integrity", value: diag.memoryHealth.integrity)
            LabeledContent("Pending / failed writes", value: "\(diag.memoryHealth.pendingWrites) / \(diag.memoryHealth.failedWrites)")
            ForEach(diag.memoryHealth.categoryCounts.keys.sorted(), id: \.self) { category in
                LabeledContent(category.replacingOccurrences(of: "_", with: " ").capitalized,
                               value: String(diag.memoryHealth.categoryCounts[category, default: 0]))
            }
            Text("Bypassed means the test mode did not allow memory reuse for that unit; it is not a miss.").font(.caption).foregroundStyle(.secondary)
            Text("Pending writes are not yet durable. RAM eviction never means permanent deletion. Lookup outcomes count translation units; persistence counters count write operations.").font(.caption).foregroundStyle(.secondary)
            ForEach(MemoryDiagnosticOutcome.allCases, id: \.self) { outcome in
                LabeledContent(humanizedKey(outcome.rawValue), value: String(diag.memoryOutcomesForUI(outcome)))
            }
            Text(diag.archiveStatus).font(.caption).foregroundStyle(.secondary)
        }.kitSurface()
    }

    var sessionsPage: some View {
        TestRunsPage(diag: diag, showReport: $showTestReport, confirmDeleteUnpinned: $confirmDeleteSessions).kitSurface()
    }

    private var liveFraction: Double {
        let now = Date()
        let total = now.timeIntervalSince(diag.started) - diag.pausedSeconds
        guard total > 1 else { return 0 }
        let live = diag.spans.filter { $0.state == .live }.reduce(0.0) { $0 + ($1.end ?? now).timeIntervalSince($1.start) }
        return Swift.min(1, live / total)
    }

    var arrow: some View {
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
    }

    private func node(_ title: String, _ icon: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.18), in: Circle())
            Text(title).font(.caption.weight(.semibold))
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    var pipelineStrip: some View {
        let o = Diagnostics.summarize(Array(diag.ocr.suffix(20)))
        let t = Diagnostics.summarize(Array(diag.translate.suffix(20)))
        let d = Diagnostics.summarize(Array(diag.latency.suffix(20)))
        let fpsColor: Color = !facts.captureAlive ? Color.red : (diag.s.fps >= 15 ? Color.green : Color.orange)
        let showColor: Color = !facts.pipActive ? Color.gray : level(d.avg, d.n, 1200, 2000)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Pipeline").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                node("Capture", "video", facts.captureAlive ? "\(Int(diag.s.fps)) fps" : "off", fpsColor)
                arrow
                node("Read", "text.viewfinder", o.n > 0 ? "\(Int(o.avg)) ms" : "–", level(o.avg, o.n, 300, 500))
                arrow
                node("Filter", "line.3.horizontal.decrease", "\(diag.s.blocksKept)/\(diag.s.blocksIn)", Color.green)
                arrow
                node(facts.system == .legacy ? "Translate" : "Model", "character.bubble",
                     t.n > 0 ? "\(Int(t.avg)) ms" : "–", level(t.avg, t.n, 400, 800))
                arrow
                node("Show", "rectangle.on.rectangle", facts.pipActive ? (d.n > 0 ? "\(Int(d.avg)) ms" : "–") : "closed", showColor)
            }
        }
        .kitSurface()
    }

    private struct CounterRow: Identifiable {
        let title: String
        let value: String
        var tint: Color = Color.primary
        let icon: String
        var id: String { title }
    }

    /// One list of session counters. Built as data so the row count never hits the ViewBuilder limit.
    var sessionGrid: some View {
        let s = diag.s
        let hits = s.cacheHits + s.savedHits + s.specHits + s.cacheMisses
        let reuse = hits == 0 ? "–" : "\(Int(Double(s.cacheHits + s.savedHits + s.specHits) / Double(hits) * 100))%"
        let rows: [CounterRow] = [
            CounterRow(title: "Time live", value: "\(Int(liveFraction * 100))%", tint: Color.green, icon: "dot.radiowaves.left.and.right"),
            CounterRow(title: "Started", value: diag.started.formatted(date: .omitted, time: .shortened), icon: "clock"),
            CounterRow(title: "Translations", value: "\(s.translations)", tint: Color.cyan, icon: "character.bubble"),
            CounterRow(title: "Sentences", value: "\(s.sentences)", icon: "text.alignleft"),
            CounterRow(title: "Characters", value: "\(s.chars)", icon: "textformat"),
            CounterRow(title: "Cache hits", value: reuse, tint: Color.purple, icon: "memorychip"),
            CounterRow(title: "Capture drops", value: "\(s.captureDrops)", tint: s.captureDrops > 0 ? Color.orange : Color.primary, icon: "bolt.slash"),
            CounterRow(title: "Failures", value: "\(s.failures)", tint: s.failures > 0 ? Color.red : Color.primary, icon: "exclamationmark.triangle"),
            CounterRow(title: "Pre-translated", value: "\(s.specHits)", tint: Color.cyan, icon: "forward.fill"),
            CounterRow(title: "Remembered", value: "\(facts.memoryCount)", tint: Color.mint, icon: "externaldrive")
        ]
        return VStack(alignment: .leading, spacing: 0) {
            Text("This session").font(.headline).padding(.bottom, KitSpace.tight)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                StatTile(title: row.title, value: row.value, tint: row.tint, icon: row.icon)
            }
        }
        .kitSurface()
    }

    var percentileTable: some View {
        let rows: [(String, Summary)] = [
            ("Reading", Diagnostics.summarize(diag.ocr)),
            ("Translating", Diagnostics.summarize(diag.translate)),
            ("Total delay", Diagnostics.summarize(diag.latency)),
            ("Transfer", Diagnostics.summarize(diag.transport))
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Timing summary (ms)").font(.subheadline.weight(.semibold))
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("avg")
                    Text("p50")
                    Text("p95")
                    Text("max")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0).font(.caption.weight(.semibold)).gridColumnAlignment(.leading)
                        Text(r.1.n > 0 ? "\(Int(r.1.avg))" : "–")
                        Text(r.1.n > 0 ? "\(Int(r.1.p50))" : "–")
                        Text(r.1.n > 0 ? "\(Int(r.1.p95))" : "–")
                        Text(r.1.n > 0 ? "\(Int(r.1.max))" : "–")
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
        .kitSurface()
    }

    // MARK: Speed
    var speedPage: some View {
        let important: Set<EventKind> = [.error, .rotation, .preset, .capture]
        let markers = Array(diag.events.filter { important.contains($0.kind) && $0.time >= rangeStart }.suffix(6))
        return VStack(spacing: 14) {
            LineCard(title: "Reading the screen", samples: slice(diag.ocr), color: Color.green, unit: "ms", rule: 300, markers: markers)
            LineCard(title: facts.system == .legacy ? "Translating" : "Completed model inference", samples: slice(diag.translate), color: Color.cyan, unit: "ms", markers: markers)
            LineCard(title: "First sighting → frame enqueue", samples: slice(diag.latency), color: Color.orange, unit: "ms", rule: 1500, markers: markers)
            LineCard(title: "Transfer extension → app", samples: slice(diag.transport), color: Color.purple, unit: "ms")
            LineCard(title: "Frames per second", samples: slice(diag.fps), color: Color.teal, unit: "fps")
            HistogramCard(title: "How long reading takes", values: slice(diag.ocr).map { $0.v }, color: Color.green)
            HistogramCard(title: "How long the total delay is", values: slice(diag.latency).map { $0.v }, color: Color.orange)
            if facts.system != .legacy {
                Text("Model-inference timings include successful backend requests even if an obsolete result was not displayed. Memory-only translations add no model sample. Total delay ends at PiP buffer enqueue.")
                    .font(.caption).foregroundStyle(.secondary).kitSurface()
            }
            PairedTimingCard(samples: diag.pipeline.filter { $0.date >= rangeStart })
            granularityCard
        }
    }

    /// Raw bucketed counts are useful for short bursts even when timing
    /// percentile sample sizes are too small to interpret meaningfully.
    private var granularityCard: some View {
        let buckets = diag.completedIntervals(seconds: bucketSeconds)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Short-interval evidence")
                .font(.subheadline.weight(.semibold))
            Picker("Time resolution", selection: $bucketSeconds) {
                Text("1 second").tag(1)
                Text("5 seconds").tag(5)
                Text("15 seconds").tag(15)
            }
            .pickerStyle(.segmented)
            if buckets.isEmpty {
                Text(bucketSeconds == 1
                     ? "No one-second buckets yet. Enable Detailed diagnostics and run capture."
                     : "No completed buckets yet at this resolution.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(Array(buckets.suffix(12)), id: \.startedAt) { bucket in
                    HStack(alignment: .top) {
                        Text(bucket.startedAt.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .frame(width: 76, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Confirmed \(bucket.counters["candidateConfirmed", default: 0]) · enqueued \(bucket.counters["candidateEnqueued", default: 0])")
                                .font(.caption)
                            Text("Superseded \(bucket.counters["unpresentedConfirmed", default: 0]) · enqueue failures \(bucket.counters["enqueueFailed", default: 0])")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Text(String(format: "%.1f s", bucket.elapsedSeconds))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Buckets use actual elapsed time. For precise event order and durations, export events.csv; for longer sessions, use 15-second intervals. Individual buckets may have too few timings for useful P95.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .kitSurface()
    }

    // MARK: Timeline
    private var stateCard: some View {
        let spans = diag.spans.filter { ($0.end ?? Date()) >= rangeStart }
        let evs = diag.events.filter { $0.time >= rangeStart && $0.kind != .translation && $0.kind != .state }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Session timeline").font(.subheadline.weight(.semibold))
            if spans.isEmpty {
                Text("No state timeline spans in this range. Capture and Detailed collection are required.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                Chart {
                    ForEach(spans) { s in
                        RectangleMark(xStart: .value("Start", Swift.max(s.start, rangeStart)),
                                      xEnd: .value("End", s.end ?? Date()),
                                      y: .value("Lane", "State"), height: .fixed(26))
                            .foregroundStyle(s.state.color.opacity(0.85))
                    }
                    ForEach(evs) { e in
                        PointMark(x: .value("Time", e.time), y: .value("Lane", "Events"))
                            .foregroundStyle(e.kind.color)
                            .symbolSize(70)
                    }
                }
                .chartXScale(domain: rangeStart...Date())
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 120)
                HStack(spacing: 12) {
                    ForEach([EngineState.live, .paused, .frozen, .idle], id: \.rawValue) { st in
                        HStack(spacing: 4) {
                            Circle().fill(st.color).frame(width: 8, height: 8)
                            Text(st.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .kitSurface()
    }

    private var perMinuteCard: some View {
        let unit: Calendar.Component = range == .oneMin ? .second : .minute
        let tr = diag.events.filter { $0.kind == .translation && $0.time >= rangeStart && $0.text.hasPrefix("Translated") }
        let grouped = Dictionary(grouping: tr) { Calendar.current.dateInterval(of: unit, for: $0.time)?.start ?? $0.time }
        let buckets = grouped.map { Bucket(date: $0.key, count: $0.value.count) }.sorted { $0.date < $1.date }
        return VStack(alignment: .leading, spacing: 8) {
            Text(range == .oneMin ? "Translations per second" : "Translations per minute").font(.subheadline.weight(.semibold))
            if buckets.isEmpty {
                Text("No translations in this period.").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                Chart(buckets) { b in
                    BarMark(x: .value("Time", b.date, unit: unit), y: .value("Translations", b.count))
                        .foregroundStyle(Color.cyan.gradient)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 120)
            }
        }
        .kitSurface()
    }

    var timelinePage: some View {
        VStack(spacing: 14) {
            stateCard
            perMinuteCard
            eventListCard(limit: 150)
        }
    }

    func eventRow(_ e: TimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.time, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(elapsed(e.time))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .frame(width: 58, alignment: .leading)
            Image(systemName: e.kind.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(e.kind.color)
                .frame(width: 24, height: 24)
                .background(e.kind.color.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(e.text).font(.caption)
                if let d = e.detail, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func kindChip(_ title: String, _ icon: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .background(on ? color.opacity(0.7) : KitColor.surface, in: Capsule())
        }
    }

    var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                kindChip("All", "line.3.horizontal.decrease.circle", on: kinds.isEmpty, color: Color.gray) { kinds = [] }
                ForEach(EventKind.allCases) { k in
                    kindChip(k.title, k.icon, on: kinds.contains(k), color: k.color) {
                        if kinds.contains(k) { kinds.remove(k) } else { kinds.insert(k) }
                    }
                }
            }
        }
    }
}
