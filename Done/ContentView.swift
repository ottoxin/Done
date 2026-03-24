import SwiftUI
import SwiftData
import Foundation
import Combine
import UniformTypeIdentifiers

// MARK: - 1) DATA MODEL

@Model
final class TodoItem {
    var title: String
    var isCompleted: Bool
    var createdAt: Date
    var completedAt: Date?
    var difficultyScore: Int
    var priority: Int
    var isComplex: Bool

    // Manual order for active tasks (0 = top)
    var sortOrder: Int?
    // AI-estimated time in minutes (nil = use difficulty fallback)
    var estimatedMinutes: Int?
    // Persisted schedule block for today
    var scheduledStart: Date?
    var scheduledEnd: Date?
    // Whether this task is planned for today vs sitting in the waitlist
    var isToday: Bool = true

    init(
        title: String,
        difficultyScore: Int = 1,
        priority: Int = 1,
        isComplex: Bool = false,
        sortOrder: Int? = nil,
        isToday: Bool = true
    ) {
        self.title = title
        self.isCompleted = false
        self.createdAt = Date()
        self.difficultyScore = difficultyScore
        self.priority = priority
        self.isComplex = isComplex
        self.sortOrder = sortOrder
        self.isToday = isToday
    }
}

enum Involvement: String, CaseIterable {
    case low = "Low involvement"
    case high = "High involvement"
}

func involvement(for difficulty: Int) -> Involvement {
    difficulty >= 3 ? .high : .low
}

/// We still store 1–5, but changing involvement sets a sensible representative value.
func difficultyValue(for involvement: Involvement) -> Int {
    involvement == .high ? 4 : 2
}

func involvementColor(_ inv: Involvement) -> Color {
    inv == .high ? .orange : .blue
}

// MARK: - 2) AI SERVICE (Ollama)

struct OllamaResponse: Decodable {
    let response: String
}

struct TaskAnalysis: Decodable {
    let difficulty: Int
    let isComplex: Bool
    let subtasks: [String]
    let estimatedMinutes: Int  // AI-provided time estimate

    init(difficulty: Int, isComplex: Bool, subtasks: [String], estimatedMinutes: Int) {
        self.difficulty = difficulty
        self.isComplex = isComplex
        self.subtasks = subtasks
        self.estimatedMinutes = estimatedMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let difficulty = (try? c.decode(Int.self, forKey: .difficulty)) ?? 1
        let isComplex = (try? c.decode(Bool.self, forKey: .isComplex)) ?? false
        let subtasks = (try? c.decode([String].self, forKey: .subtasks)) ?? []
        // Fall back to difficulty-based estimate if AI doesn't provide one
        let fallback = [1: 15, 2: 25, 3: 45, 4: 60, 5: 90][difficulty] ?? 30
        let estimatedMinutes = (try? c.decode(Int.self, forKey: .estimatedMinutes)) ?? fallback
        self.init(difficulty: difficulty, isComplex: isComplex, subtasks: subtasks, estimatedMinutes: estimatedMinutes)
    }

    enum CodingKeys: String, CodingKey {
        case difficulty, isComplex, subtasks, estimatedMinutes
    }
}

final class OllamaService {
    // Ensure Ollama is running locally with: ollama run qwen3:0.6b
    func generate(prompt: String, jsonMode: Bool) async -> String? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }

        var body: [String: Any] = [
            "model": "qwen3:0.6b",
            "prompt": prompt,
            "stream": false,
            "options": ["temperature": 0.3, "num_predict": 200]
        ]
        if jsonMode { body["format"] = "json" }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let result = try JSONDecoder().decode(OllamaResponse.self, from: data)
            return result.response
        } catch {
            print("AI Service Error: \(error)")
            return nil
        }
    }

    func analyzeTask(title: String) async -> TaskAnalysis? {
        let prompt = """
        You are a strict JSON generator.

        Task: "\(title)"

        Return ONLY valid JSON matching this schema exactly:
        {
          "difficulty": <integer 1-5>,
          "isComplex": <boolean>,
          "subtasks": <array of 0-3 strings>
        }

        Rules:
        - No markdown, no comments, no extra keys, no extra text.
        - If no subtasks, return "subtasks": [].
        - Each subtask string: trim spaces.
        - If a subtask begins with an English letter, capitalize the first letter.
        """

        guard let raw = await generate(prompt: prompt, jsonMode: true) else { return nil }
        let cleaned = raw.extractFirstJSONObject() ?? raw
        guard let data = cleaned.data(using: .utf8) else { return nil }

        return try? JSONDecoder().decode(TaskAnalysis.self, from: data)
    }

    func getFocusTip(title: String) async -> String {
        let prompt = "Task: \"\(title)\". Give 1 very short micro-strategy (under 10 words) to start. Be motivating."
        return await generate(prompt: prompt, jsonMode: false) ?? "Just take the first step."
    }
}

// MARK: - 3) DEEP WORK COUNTER (UserDefaults)

enum DeepWorkStore {
    private static let key = "deepWorkSessionsByDate"

    private static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func load() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    private static func save(_ dict: [String: Int]) {
        let data = try? JSONEncoder().encode(dict)
        UserDefaults.standard.set(data, forKey: key)
    }

    static func countToday() -> Int {
        let dict = load()
        return dict[dayKey()] ?? 0
    }

    static func incrementToday() {
        var dict = load()
        let k = dayKey()
        dict[k] = (dict[k] ?? 0) + 1
        save(dict)
    }
}

// MARK: - 4) APP ENTRY

@main
struct SmartTodosApp: App {
    @StateObject private var menuBarState = MenuBarState.shared

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([TodoItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }
        // Migration failed (schema changed) — wipe the store and start fresh
        let base = config.url.path
        for path in [base, base + "-wal", base + "-shm"] {
            try? FileManager.default.removeItem(atPath: path)
        }
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer after store reset: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup { ContentView() }
            .modelContainer(sharedModelContainer)
            .defaultSize(width: 960, height: 680)
        #if os(macOS)
            .windowStyle(.hiddenTitleBar)
        #endif

        #if os(macOS)
        MenuBarExtra {
            MenuBarTaskView()
                .modelContainer(sharedModelContainer)
        } label: {
            MenuBarLabel(state: menuBarState)
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView() }
        #endif
    }
}

// The bar shown in the system menu bar — radial tick dial + task name
struct MenuBarLabel: View {
    @ObservedObject var state: MenuBarState

    /// Unified progress: Pomodoro in focus mode, block progress otherwise
    private var dialProgress: Double {
        if state.isFocusMode { return state.focusProgress }
        if let bp = state.blockProgress { return bp }
        return 0
    }

    private var isLive: Bool {
        state.isFocusMode ? state.focusIsRunning : (state.blockProgress != nil)
    }

    var body: some View {
        HStack(spacing: 5) {
            if state.activeCount == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.green)
            } else {
                RadialTickView(progress: dialProgress, isActive: isLive)
                    .frame(width: 18, height: 18)
            }

            if let title = state.currentTaskTitle {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .leading)
            } else {
                Text("Done")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .fixedSize()
    }
}

/// Radial tick-mark dial drawn with standard SwiftUI shapes (works in MenuBarExtra).
/// Filled ticks = elapsed; faint ticks = remaining.
struct RadialTickView: View {
    let progress: Double   // 0.0 → 1.0
    let isActive: Bool
    private let tickCount: Int = 36  // one tick every 10°

    var body: some View {
        let clamped: Double = min(max(progress, 0), 1)
        let filled: Int = Int((Double(tickCount) * clamped).rounded())

        ZStack {
            ForEach(0..<tickCount, id: \.self) { i in
                tickMark(index: i, isFilled: i < filled)
            }
        }
    }

    private func tickMark(index: Int, isFilled: Bool) -> some View {
        Capsule()
            .fill(Color.primary.opacity(isFilled ? 0.85 : 0.15))
            .frame(width: isFilled && isActive ? 2.0 : 1.0, height: 3.5)
            .offset(y: -6.5)
            .rotationEffect(.degrees(Double(index) * (360.0 / Double(tickCount))))
    }
}

// MARK: - 5) MAIN VIEW

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [TodoItem]

    @State private var newTaskTitle = ""
    @State private var isAnalyzing = false
    @State private var isFocusMode = false

    // AI approval state
    @State private var pendingAnalysis: TaskAnalysis?
    @State private var pendingTaskTitle: String = ""
    @State private var showApprovalSheet = false

    // Deep work count for today
    @State private var deepWorkToday = DeepWorkStore.countToday()
    @State private var draggingTask: TodoItem?

    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var sharedState = SharedStateService.shared

    private func nextActiveSortOrder() -> Int {
        // Only consider Today tasks so Someday tasks don't pollute the order space
        let today = items.filter { !$0.isCompleted && $0.isToday }
        return (today.compactMap { $0.sortOrder }.max() ?? -1) + 1
    }

    private func normalizeActiveSortOrdersIfNeeded() {
        // Only normalize Today tasks — Someday tasks don't need a stable sortOrder
        let today = items.filter { !$0.isCompleted && $0.isToday }
        guard !today.isEmpty else { return }

        let hasNil = today.contains(where: { $0.sortOrder == nil })
        let unique = Set(today.compactMap { $0.sortOrder })
        let hasDuplicates = unique.count != today.compactMap { $0.sortOrder }.count

        if hasNil || hasDuplicates {
            let sorted = today.sorted { $0.createdAt < $1.createdAt }
            for (i, t) in sorted.enumerated() { t.sortOrder = i }
            try? modelContext.save()
        }
    }

    private func applyReorder(from: Int, to: Int, active: [TodoItem]) {
        var arr = active
        guard from != to,
              from >= 0, from < arr.count,
              to >= 0, to < arr.count
        else { return }

        let moving = arr.remove(at: from)
        arr.insert(moving, at: to)

        for (i, t) in arr.enumerated() {
            t.sortOrder = i
        }
    }

    private var displayItems: [TodoItem] {
        items.sorted { a, b in
            if a.isCompleted != b.isCompleted { return !a.isCompleted }

            if !a.isCompleted {
                let ao = a.sortOrder ?? Int.max
                let bo = b.sortOrder ?? Int.max
                if ao != bo { return ao < bo }
                return a.createdAt < b.createdAt
            } else {
                let ad = a.completedAt ?? a.createdAt
                let bd = b.completedAt ?? b.createdAt
                if ad != bd { return ad > bd }
                return a.createdAt > b.createdAt
            }
        }
    }

    private var activeTasks: [TodoItem] { displayItems.filter { !$0.isCompleted && $0.isToday } }
    private var waitlistTasks: [TodoItem] { displayItems.filter { !$0.isCompleted && !$0.isToday } }

    private var completedTasksByDate: [(Date, [TodoItem])] {
        let completed = items.filter { $0.isCompleted }
        let grouped = Dictionary(grouping: completed) { item -> Date in
            let date = item.completedAt ?? item.createdAt
            return Calendar.current.startOfDay(for: date)
        }
        return grouped.sorted { $0.key > $1.key }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                activeCount: activeTasks.count,
                allItems: displayItems,
                deepWorkCountToday: deepWorkToday,
                calendar: calendar
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            ZStack(alignment: .bottom) {
                Color(NSColor.windowBackgroundColor).ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    if isFocusMode {
                        FocusModeView(
                            tasks: activeTasks,
                            sessionsToday: deepWorkToday,
                            onFinishSession: {
                                DeepWorkStore.incrementToday()
                                deepWorkToday = DeepWorkStore.countToday()
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        mainList
                    }
                }

                if !isFocusMode {
                    InputBarView(
                        text: $newTaskTitle,
                        isAnalyzing: isAnalyzing,
                        onCommit: analyzeTask
                    )
                    .padding(.bottom, 10)
                }
            }
        }
        .sheet(isPresented: $showApprovalSheet) {
            TaskApprovalView(
                title: pendingTaskTitle,
                analysis: pendingAnalysis,
                onConfirmSingle: addSingleTask,
                onConfirmSplit: addSplitTasks
            )
            .presentationDetents([.fraction(0.42), .medium])
            .presentationCornerRadius(30)
            .presentationBackground(.ultraThinMaterial)
        }
        .onAppear {
            deepWorkToday = DeepWorkStore.countToday()
            // One-time migration: isToday was added after initial release.
            // SwiftData defaults new Bool columns to false — flip all existing tasks back to today.
            if !UserDefaults.standard.bool(forKey: "todayFieldMigrated") {
                for item in items where !item.isCompleted {
                    item.isToday = true
                }
                try? modelContext.save()
                UserDefaults.standard.set(true, forKey: "todayFieldMigrated")
            }
            normalizeActiveSortOrdersIfNeeded()
        }
        .task {
            await CalendarService.shared.requestAccessIfNeeded()
            CalendarService.shared.scheduleTasks(activeTasks)
            persistScheduledBlocks()
            MenuBarState.shared.update(tasks: items)
            SharedStateService.shared.exportState(tasks: items, freeMinutes: calendar.totalFreeMinutesToday)
            SharedStateService.shared.startWatching()
        }
        .onChange(of: activeTasks.count) { _, _ in
            CalendarService.shared.scheduleTasks(activeTasks)
            persistScheduledBlocks()
            MenuBarState.shared.update(tasks: items)
            SharedStateService.shared.exportState(tasks: items, freeMinutes: calendar.totalFreeMinutesToday)
        }
        .onChange(of: activeTasks.map { CalendarService.shared.estimatedMinutes(for: $0) }.reduce(0, +)) { _, _ in
            CalendarService.shared.scheduleTasks(activeTasks)
            persistScheduledBlocks()
            MenuBarState.shared.update(tasks: items)
            SharedStateService.shared.exportState(tasks: items, freeMinutes: calendar.totalFreeMinutesToday)
        }
        .onChange(of: sharedState.pendingUpdates) { _, updates in
            guard let updates else { return }
            sharedState.applyUpdates(updates, tasks: items, context: modelContext)
        }
        .alert("Plan updated", isPresented: .init(
            get: { sharedState.lastAppliedMessage != nil },
            set: { if !$0 { sharedState.lastAppliedMessage = nil } }
        )) {
            Button("OK") { sharedState.lastAppliedMessage = nil }
        } message: {
            Text(sharedState.lastAppliedMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isFocusMode ? "Deep Work" : "Today")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(Date(), format: .dateTime.weekday(.wide).month().day())
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { isFocusMode.toggle() }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: isFocusMode ? "xmark" : "timer")
                        .font(.system(size: 16, weight: .bold))
                    Text(isFocusMode ? "End" : "Focus")
                        .fontWeight(.semibold)
                }
                .frame(width: 118, height: 36)
                .background(Capsule().fill(isFocusMode ? Color.gray.opacity(0.1) : Color.blue))
                .foregroundStyle(isFocusMode ? Color.primary : Color.white)
                .shadow(color: isFocusMode ? .clear : .blue.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    private var mainList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if activeTasks.isEmpty && waitlistTasks.isEmpty && completedTasksByDate.isEmpty {
                    EmptyStateView().padding(.top, 40)
                } else {

                    // ── TODAY ─────────────────────────────────────────
                    taskSection(label: "Today", badge: activeTasks.count, tasks: activeTasks, isToday: true)

                    // ── SOMEDAY ───────────────────────────────────────
                    if !waitlistTasks.isEmpty {
                        taskSection(label: "Someday", badge: waitlistTasks.count, tasks: waitlistTasks, isToday: false)
                    }

                    // ── COMPLETED ─────────────────────────────────────
                    if !completedTasksByDate.isEmpty {
                        ForEach(completedTasksByDate, id: \.0) { date, tasks in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(date, format: .dateTime.month().day())
                                    .font(.subheadline).fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24).padding(.top, 16)
                                ForEach(tasks) { item in
                                    TaskRowView(item: item, onDelete: {
                                        withAnimation { modelContext.delete(item) }
                                    })
                                    .padding(.horizontal, 20)
                                }
                            }
                        }
                    }
                }
                Color.clear.frame(height: 100)
            }
            .padding(.top, 10)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func taskSection(label: String, badge: Int, tasks: [TodoItem], isToday: Bool) -> some View {
        if !tasks.isEmpty || isToday {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.headline).foregroundStyle(.secondary)
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(isToday ? Color.blue : Color.gray.opacity(0.5)))
                    }
                    Spacer()
                }
                .padding(.horizontal, 24).padding(.top, 8)

                if tasks.isEmpty && isToday {
                    Text("No tasks for today — add one below or move one from Someday.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                }

                ForEach(tasks) { item in
                    TaskRowView(item: item, onDelete: {
                        withAnimation { modelContext.delete(item) }
                    })
                    .padding(.horizontal, 20)
                    .modifier(DragDropModifier(
                        enabled: isToday,
                        item: item,
                        draggingTask: $draggingTask,
                        activeProvider: { activeTasks },
                        onReorder: { from, to, active in
                            withAnimation(.snappy) { applyReorder(from: from, to: to, active: active) }
                        }
                    ))
                }
            }
        }
    }

    private func analyzeTask() {
        let raw = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        pendingTaskTitle = raw // keep user input as-is for title
        newTaskTitle = ""
        isAnalyzing = true

        Task {
            let analysis = await makeLLMService().analyzeTask(title: pendingTaskTitle)

            await MainActor.run {
                if let a = analysis {
                    // local enforced cleanup and capitalization for English-leading subtasks
                    let cleanedSubs = a.subtasks
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .prefix(3)
                        .map { String($0).capitalizingFirstLetterIfEnglish() }

                    let clamped = min(5, max(1, a.difficulty))
                    self.pendingAnalysis = TaskAnalysis(
                        difficulty: clamped,
                        isComplex: a.isComplex,
                        subtasks: Array(cleanedSubs),
                        estimatedMinutes: a.estimatedMinutes
                    )
                } else {
                    self.pendingAnalysis = nil
                }

                self.isAnalyzing = false
                self.showApprovalSheet = true
            }
        }
    }

    private func addSingleTask() {
        let title = pendingTaskTitle.capitalizingFirstLetterIfEnglish()
        let newItem = TodoItem(
            title: title,
            difficultyScore: pendingAnalysis?.difficulty ?? 1,
            isComplex: pendingAnalysis?.isComplex ?? false,
            sortOrder: nextActiveSortOrder()
        )
        newItem.estimatedMinutes = pendingAnalysis?.estimatedMinutes
        modelContext.insert(newItem)
        showApprovalSheet = false
    }

    private func persistScheduledBlocks() {
        let blocks = CalendarService.shared.scheduledBlocks
        let scheduled = Dictionary(uniqueKeysWithValues: blocks.map { ($0.taskID, $0) })
        for item in activeTasks {
            let block = scheduled[item.id]
            item.scheduledStart = block?.start
            item.scheduledEnd   = block?.end
        }
        try? modelContext.save()
    }

    private func addSplitTasks() {
        if let analysis = pendingAnalysis, !analysis.subtasks.isEmpty {
            let subMinutes = analysis.estimatedMinutes > 0
                ? max(10, analysis.estimatedMinutes / analysis.subtasks.count)
                : nil
            for sub in analysis.subtasks {
                let subDifficulty = max(1, analysis.difficulty - 1)
                let newItem = TodoItem(
                    title: sub.capitalizingFirstLetterIfEnglish(),
                    difficultyScore: subDifficulty,
                    sortOrder: nextActiveSortOrder()
                )
                newItem.estimatedMinutes = subMinutes
                modelContext.insert(newItem)
            }
        } else {
            addSingleTask()
        }
        showApprovalSheet = false
    }
}

/// MARK: - 6) SUBVIEWS

/// Applies drag-and-drop only for Today tasks; Someday tasks are unordered.
struct DragDropModifier: ViewModifier {
    let enabled: Bool
    let item: TodoItem
    @Binding var draggingTask: TodoItem?
    let activeProvider: () -> [TodoItem]
    let onReorder: (Int, Int, [TodoItem]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    draggingTask = item
                    return NSItemProvider(object: "\(item.id)" as NSString)
                }
                .onDrop(of: [UTType.text], delegate: ActiveTaskDropDelegate(
                    target: item,
                    activeProvider: activeProvider,
                    dragging: $draggingTask,
                    onReorder: onReorder
                ))
        } else {
            content
        }
    }
}

struct ActiveTaskDropDelegate: DropDelegate {
    let target: TodoItem
    let activeProvider: () -> [TodoItem]
    @Binding var dragging: TodoItem?
    let onReorder: (_ from: Int, _ to: Int, _ active: [TodoItem]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging = dragging else { return }
        if dragging.id == target.id { return }

        let active = activeProvider()
        guard
            let from = active.firstIndex(where: { $0.id == dragging.id }),
            let to = active.firstIndex(where: { $0.id == target.id })
        else { return }

        onReorder(from, to, active)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct TaskApprovalView: View {
    let title: String
    let analysis: TaskAnalysis?
    var onConfirmSingle: () -> Void
    var onConfirmSplit: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text("AI Suggestions")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 24)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                HStack(spacing: 8) {
                    let inv = involvement(for: analysis?.difficulty ?? 1)
                    Badge(text: inv.rawValue, color: involvementColor(inv))

                    if analysis?.isComplex == true {
                        Badge(text: "Complex", color: .purple)
                    }

                    if let mins = analysis?.estimatedMinutes, mins > 0 {
                        Badge(text: "~\(mins)m", color: .gray)
                    }
                }
            }
            .padding(.horizontal)

            if let analysis, !analysis.subtasks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple)
                        Text("Suggested Breakdown")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(analysis.subtasks, id: \.self) { sub in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "circle.dashed")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)

                                // Bigger font for subtasks
                                Text(sub)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.05))
                    )
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    // Keep One: visible outline
                    Button(action: onConfirmSingle) {
                        Text("Keep One")
                            .font(.callout)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(.blue)
                            .background(
                                Capsule()
                                    .stroke(Color.blue.opacity(0.85), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: onConfirmSplit) {
                        Text("Break Down")
                            .font(.callout)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            } else {
                Text("Looks like a straightforward task.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(action: onConfirmSingle) {
                    Text("Add to List")
                        .font(.callout)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.bottom, 10)
            }

            Spacer(minLength: 0)
        }
    }
}

struct SidebarView: View {
    let activeCount: Int
    let allItems: [TodoItem]
    let deepWorkCountToday: Int
    @ObservedObject var calendar: CalendarService

    private var completionRate: Double {
        let total = Double(allItems.count)
        guard total > 0 else { return 0 }
        let completed = Double(allItems.filter { $0.isCompleted }.count)
        return completed / total
    }

    private var pending: [TodoItem] {
        allItems.filter { !$0.isCompleted && $0.isToday }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Overview
                VStack(alignment: .leading, spacing: 16) {
                    Text("Overview")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(activeCount)")
                                .font(.system(size: 48, weight: .bold, design: .rounded))

                            Text("Pending Tasks")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("Deep Work Today: \(deepWorkCountToday)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        CircularProgressView(progress: completionRate)
                            .frame(width: 92, height: 92)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.gray.opacity(0.05))
                        .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 5)
                )

                // Calendar / Free time card
                CalendarCard(calendar: calendar)

                // Queue / Celebration
                if pending.isEmpty {
                    CelebrationCard()
                } else {
                    QueueCard(pending: Array(pending.prefix(4)))
                }

                // Momentum
                VStack(alignment: .leading, spacing: 12) {
                    Text("Momentum")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)

                    HeatmapView(items: allItems)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.gray.opacity(0.05))
                        )
                }
            }
            .padding()
        }
    }
}

// MARK: - Calendar Card (sidebar)

struct CalendarCard: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Today's Schedule", systemImage: "calendar")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                if calendar.isAuthorized {
                    Button {
                        Task { await calendar.refreshToday() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if !calendar.isAuthorized {
                VStack(spacing: 8) {
                    if calendar.isDenied {
                        // Already denied — macOS won't show the dialog again
                        Text("Calendar access was denied. Enable it in System Settings to see your schedule.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")!
                            )
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.blue)
                    } else {
                        // Not asked yet
                        Text("Grant calendar access to see free time blocks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Allow Calendar Access") {
                            Task { await calendar.requestAccessIfNeeded() }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: .infinity)
            } else if calendar.todayFreeSlots.isEmpty && calendar.busyEvents.isEmpty {
                Text("No events today — your day is wide open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Free time summary
                if calendar.totalFreeMinutesToday > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("\(calendar.totalFreeMinutesToday) min free today")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }
                }

                // Scheduled task blocks
                if !calendar.scheduledBlocks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SUGGESTED BLOCKS")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .tracking(1)

                        ForEach(calendar.scheduledBlocks.prefix(5)) { block in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.blue.opacity(0.7))
                                    .frame(width: 3, height: 28)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(block.taskTitle)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Text(block.formattedTime)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(block.durationMinutes)m")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // Busy events
                if !calendar.busyEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("BUSY")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .tracking(1)

                        ForEach(Array(calendar.busyEvents.prefix(3))) { event in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.orange.opacity(0.7))
                                    .frame(width: 3, height: 20)

                                Text(event.title)
                                    .font(.system(size: 11))
                                    .lineLimit(1)

                                Spacer()

                                Text(event.start, style: .time)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.gray.opacity(0.05))
        )
    }
}

struct QueueCard: View {
    let pending: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack(alignment: .firstTextBaseline) {
                Text("Next")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text("Top task is your current focus.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(Array(pending.enumerated()), id: \.element.id) { idx, item in
                    QueueItemRow(item: item, isCurrent: idx == 0, pulse: false)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.gray.opacity(0.05))
        )
    }
}

struct QueueItemRow: View {
    let item: TodoItem
    let isCurrent: Bool
    let pulse: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isCurrent {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 16, height: 16)
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                }
            } else {
                let inv = involvement(for: item.difficultyScore)

                Circle()
                    .fill(involvementColor(inv).opacity(0.9))
                    .frame(width: 10, height: 10)
            }

            Text(item.title)
                .font(isCurrent ? .title3.weight(.semibold) : .body)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            if isCurrent {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(Color.blue)
                    .opacity(0.85)
            }
        }
        .padding(.horizontal, isCurrent ? 14 : 12)
        .padding(.vertical, isCurrent ? 14 : 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isCurrent ? Color.blue.opacity(0.08) : Color.gray.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isCurrent ? Color.blue.opacity(0.10) : .clear, lineWidth: 1)
        )
        .shadow(color: isCurrent ? Color.blue.opacity(0.05) : .clear,
                radius: isCurrent ? 10 : 0, x: 0, y: 6)
    }

    private func difficultyColor(_ score: Int) -> Color {
        switch score {
        case 4...5: return .red
        case 3: return .orange
        default: return .blue
        }
    }
}


struct PulsingDot: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(isOn ? 0.18 : 0.10))
                .frame(width: isOn ? 18 : 14, height: isOn ? 18 : 14)

            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
        }
        .animation(.easeInOut(duration: 1.1), value: isOn)
    }
}

struct InvolvementPickerPill: View {
    @Bindable var item: TodoItem
    @State private var show = false

    private var current: Involvement { involvement(for: item.difficultyScore) }

    private var iconName: String {
        current == .high ? "flame.fill" : "leaf.fill"
    }

    var body: some View {
        Button {
            withAnimation(.snappy) { show.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(involvementColor(current))

                Text(current.rawValue)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(involvementColor(current))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(involvementColor(current).opacity(0.12))
            )
            .overlay(
                Capsule().stroke(involvementColor(current).opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $show, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Involvement")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    optionRow(.low)
                    optionRow(.high)
                }
            }
            .padding(12)
            .frame(width: 240)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .padding(10)
        }
    }

    @ViewBuilder
    private func optionRow(_ inv: Involvement) -> some View {
        let isSelected = (current == inv)
        let invIcon = (inv == .high) ? "flame.fill" : "leaf.fill"

        Button {
            item.difficultyScore = difficultyValue(for: inv)
            show = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: invIcon)
                    .foregroundStyle(involvementColor(inv))

                Text(inv.rawValue)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(involvementColor(inv))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? involvementColor(inv).opacity(0.14) : Color.gray.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(involvementColor(inv).opacity(isSelected ? 0.30 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct TaskRowView: View {
    @Bindable var item: TodoItem
    var onDelete: () -> Void

    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Checkbox
            Button(action: toggleCompleted) {
                ZStack {
                    Circle()
                        .stroke(item.isCompleted ? Color.green : Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)

                    if item.isCompleted {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 16, height: 16)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                // Title (click to edit)
                if isEditingTitle {
                    TextField("", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.body.weight(.medium))
                        .focused($titleFocused)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onAppear {
                            draftTitle = item.title
                            DispatchQueue.main.async { titleFocused = true }
                        }
                        .onSubmit { commitTitleEdit() }
                        .onChange(of: titleFocused) { _, focused in
                            if !focused { commitTitleEdit() }
                        }
                } else {
                    Text(item.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .strikethrough(item.isCompleted)
                        .foregroundStyle(item.isCompleted ? .secondary : .primary)
                        .opacity(item.isCompleted ? 0.7 : 1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.snappy) { isEditingTitle = true }
                        }
                }

                if !item.isCompleted {
                    HStack(spacing: 8) {
                        InvolvementPickerPill(item: item)
                        .buttonStyle(.plain)
                        if item.isComplex {
                            Badge(text: "Complex", color: .purple)
                        }
                        if let start = item.scheduledStart, let end = item.scheduledEnd {
                            HStack(spacing: 3) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9, weight: .medium))
                                Text("\(start, style: .time) – \(end, style: .time)")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.gray.opacity(0.08)))
                        }
                        // Today / Someday toggle
                        Button {
                            withAnimation(.snappy) { item.isToday.toggle() }
                        } label: {
                            Text(item.isToday ? "Today" : "Someday")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(item.isToday ? .blue : .secondary)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(Capsule().fill(item.isToday ? Color.blue.opacity(0.1) : Color.gray.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.red.opacity(0.4))
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)
        )
    }

    private func toggleCompleted() {
        withAnimation(.snappy) {
            item.isCompleted.toggle()
            if item.isCompleted {
                item.completedAt = Date()
            } else {
                item.completedAt = nil
            }
        }
    }

    private func commitTitleEdit() {
        let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            item.title = t.capitalizingFirstLetterIfEnglish()
        }
        withAnimation(.snappy) { isEditingTitle = false }
    }

    private func difficultyColor(_ score: Int) -> Color {
        switch score {
        case 4...5: return .red
        case 3: return .orange
        default: return .blue
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.1))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct InputBarView: View {
    @Binding var text: String
    var isAnalyzing: Bool
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            TextField("New Task...", text: $text)
                .font(.body)
                .submitLabel(.done)
                .onSubmit(onCommit)
            #if os(macOS)
                .textFieldStyle(.plain) // removes default gray box styling
                .modifier(DisableFocusRingIfAvailable())
            #endif
                .padding(.horizontal, 8)

            if isAnalyzing {
                ProgressView()
                    .tint(Color.blue)
                    .frame(width: 24)
            } else {
                Button(action: onCommit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.3) : Color.blue)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.gray.opacity(0.1)), alignment: .top)
        .padding(.horizontal, 0)
    }
}

struct FocusModeView: View {
    let tasks: [TodoItem]
    var sessionsToday: Int = 0
    var onFinishSession: () -> Void = {}

    @State private var timeLeft = 25 * 60
    @State private var isRunning = false
    @State private var didFinishThisRun = false

    var currentTask: TodoItem? { tasks.first }

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let ringSize = min(340, min(geo.size.width * 0.78, geo.size.height * 0.50))
            let topPad: CGFloat = 10
            let sectionGap: CGFloat = 22

            VStack(spacing: sectionGap) {

                // Timer
                ZStack {
                    Circle()
                        .stroke(lineWidth: 4)
                        .opacity(0.10)
                        .foregroundColor(.gray)
                        .frame(width: ringSize, height: ringSize)

                    Circle()
                        .trim(from: 0.0, to: CGFloat(timeLeft) / CGFloat(25 * 60))
                        .stroke(
                            Color.blue,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                        )
                        .rotationEffect(.degrees(270))
                        .animation(.linear(duration: 1), value: timeLeft)
                        .frame(width: ringSize, height: ringSize)

                    VStack(spacing: 8) {
                        Text(formatTime(timeLeft))
                            .font(.system(size: ringSize * 0.28, weight: .light, design: .rounded))
                            .contentTransition(.numericText())

                        Text(isRunning ? "FOCUSING" : "READY")
                            .font(.caption)
                            .fontWeight(.bold)
                            .tracking(4)
                            .foregroundStyle(isRunning ? Color.blue : Color.secondary)

                        // Sessions pill
                        HStack(spacing: 8) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.orange)

                            Text("Sessions")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)

                            Text("\(sessionsToday)")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.gray.opacity(0.07)))
                        .padding(.top, 2)
                    }
                }
                .padding(.top, topPad)

                // Task
                VStack(spacing: 10) {
                    Text("CURRENT TASK")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .tracking(2)

                    Text(currentTask?.title ?? "No tasks pending!")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 18)
                }
                .padding(.top, 6)

                // Controls
                HStack(alignment: .center, spacing: 44) {
                    Button(action: {
                        withAnimation(.snappy) {
                            isRunning = false
                            timeLeft = 25 * 60
                            didFinishThisRun = false
                            MenuBarState.shared.focusTimeLeft = 25 * 60
                            MenuBarState.shared.focusIsRunning = false
                        }
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                            Text("Reset")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 70)
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            if !isRunning { didFinishThisRun = false }
                            isRunning.toggle()
                            MenuBarState.shared.focusIsRunning = isRunning
                        }
                    }) {
                        Image(systemName: isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 82, height: 82)
                            .background(Circle().fill(Color.blue))
                            .shadow(color: .blue.opacity(0.18), radius: 14, x: 0, y: 10)
                    }
                    .buttonStyle(.plain)

                    Color.clear.frame(width: 70, height: 1)
                }
                .padding(.top, 6)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 28)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            MenuBarState.shared.isFocusMode = true
            MenuBarState.shared.focusTimeLeft = timeLeft
            MenuBarState.shared.focusIsRunning = isRunning
        }
        .onDisappear {
            MenuBarState.shared.isFocusMode = false
            MenuBarState.shared.focusIsRunning = false
        }
        .onReceive(timer) { _ in
            guard isRunning else { return }

            if timeLeft > 0 {
                timeLeft -= 1
            }
            MenuBarState.shared.focusTimeLeft = timeLeft
            MenuBarState.shared.focusIsRunning = isRunning

            // Session just finished
            if timeLeft == 0, !didFinishThisRun {
                didFinishThisRun = true
                isRunning = false
                MenuBarState.shared.focusIsRunning = false
                onFinishSession()
            }
        }
    }

    private func formatTime(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct CelebrationCard: View {
    @State private var showConfetti = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.gray.opacity(0.05))

            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)

                Text("All caught up!")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)

                Text("Nice work. Take a breath.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            if showConfetti {
                ConfettiView()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { showConfetti = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.easeOut(duration: 0.4)) { showConfetti = false }
            }
        }
    }
}

private struct ConfettiPiece: Identifiable {
    let id = UUID()
    let x: CGFloat
    let size: CGFloat
    let delay: Double
    let duration: Double
    let color: Color
    let spin: Double
}

struct ConfettiView: View {
    private let pieces: [ConfettiPiece] = {
        let colors: [Color] = [.blue, .green, .purple, .orange, .pink, .teal]
        return (0..<28).map { _ in
            ConfettiPiece(
                x: .random(in: 0.05...0.95),
                size: .random(in: 6...12),
                delay: .random(in: 0.0...0.6),
                duration: .random(in: 0.9...1.6),
                color: colors.randomElement() ?? .blue,
                spin: .random(in: -180...180)
            )
        }
    }()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { p in
                    ConfettiParticle(piece: p, size: geo.size)
                }
            }
        }
    }
}

private struct ConfettiParticle: View {
    let piece: ConfettiPiece
    let size: CGSize

    @State private var y: CGFloat = -20
    @State private var rotation: Double = 0
    @State private var opacity: Double = 1

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(piece.color.opacity(0.9))
            .frame(width: piece.size, height: piece.size * 0.55)
            .position(x: piece.x * size.width, y: y)
            .rotationEffect(.degrees(rotation))
            .opacity(opacity)
            .onAppear {
                y = -20
                rotation = 0
                opacity = 1

                withAnimation(.easeIn(duration: piece.duration).delay(piece.delay)) {
                    y = size.height + 30
                    rotation = piece.spin
                    opacity = 0.0
                }
            }
    }
}

struct CircularProgressView: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 10)
                .opacity(0.1)
                .foregroundColor(.blue)

            Circle()
                .trim(from: 0.0, to: CGFloat(min(progress, 1.0)))
                .stroke(style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .foregroundColor(.blue)
                .rotationEffect(Angle(degrees: 270.0))
                .animation(.linear, value: progress)

            Text("\(Int(progress * 100))%")
                .font(.system(size: 16, weight: .bold, design: .rounded))
        }
    }
}

struct HeatmapView: View {
    let items: [TodoItem]

    private let cols = 7
    private let totalDays = 28
    private let spacing: CGFloat = 8

    @State private var hoveredIndex: Int? = nil

    private func date(for dayOffset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date())!
    }

    private func completedCount(for dayOffset: Int) -> Int {
        let d = date(for: dayOffset)
        return items.filter {
            guard let completedAt = $0.completedAt else { return false }
            return Calendar.current.isDate(completedAt, inSameDayAs: d)
        }.count
    }

    private func opacity(for dayOffset: Int) -> Double {
        let count = completedCount(for: dayOffset)
        if count == 0 { return 0.12 }
        return min(0.25 + Double(count) * 0.18, 1.0)
    }

    private func tooltipPosition(
        index: Int,
        cell: CGFloat,
        gridWidth: CGFloat,
        gridHeight: CGFloat
    ) -> CGPoint {
        let row = index / cols
        let col = index % cols

        let x = CGFloat(col) * (cell + spacing) + cell / 2
        var y = CGFloat(row) * (cell + spacing) - 14   // above the cell

        // If tooltip would go above the grid, place it below the cell.
        if y < 8 {
            y = CGFloat(row) * (cell + spacing) + cell + 18
        }

        // Clamp inside grid bounds (so it doesn't look cut off at edges)
        let clampedX = min(max(x, 60), gridWidth - 60)
        let clampedY = min(max(y, 10), gridHeight - 10)

        return CGPoint(x: clampedX, y: clampedY)
    }

    var body: some View {
        GeometryReader { geo in
            // Compute square size to fill width nicely.
            let raw = (geo.size.width - CGFloat(cols - 1) * spacing) / CGFloat(cols)
            let cell = min(26, max(16, floor(raw))) // feel free to tweak cap 26/16

            let rows = Int(ceil(Double(totalDays) / Double(cols)))
            let gridWidth = cell * CGFloat(cols) + spacing * CGFloat(cols - 1)
            let gridHeight = cell * CGFloat(rows) + spacing * CGFloat(rows - 1)

            ZStack(alignment: .topLeading) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cell), spacing: spacing), count: cols),
                    alignment: .leading,
                    spacing: spacing
                ) {
                    ForEach(0..<totalDays, id: \.self) { i in
                        let dayOffset = (totalDays - 1) - i
                        let count = completedCount(for: dayOffset)

                        let radius = max(4, cell * 0.22)   // tweak 0.22 for more/less rounding

                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(Color.blue.opacity(opacity(for: dayOffset)))
                            .frame(width: cell, height: cell)
                            .overlay(
                                RoundedRectangle(cornerRadius: radius, style: .continuous)
                                    .stroke(Color.black.opacity(hoveredIndex == i ? 0.08 : 0.0), lineWidth: 1)
                            )

                            .contentShape(Rectangle())
                            .onHover { hovering in
                                withAnimation(.easeOut(duration: 0.12)) {
                                    hoveredIndex = hovering ? i : (hoveredIndex == i ? nil : hoveredIndex)
                                }
                            }
                            .accessibilityLabel("Finished \(count) todos")
                    }
                }
                .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)

                if let i = hoveredIndex {
                    let dayOffset = (totalDays - 1) - i
                    let count = completedCount(for: dayOffset)
                    let d = date(for: dayOffset)

                    Text("Finished \(count) todos on \(d, format: .dateTime.month().day())")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.78))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false) // critical: prevents hover flicker
                        .position(tooltipPosition(index: i, cell: cell, gridWidth: gridWidth, gridHeight: gridHeight))
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading) // fills the card, grid stays aligned
            .frame(height: gridHeight) // keeps layout stable
        }
        .frame(height: 26 * 4 + spacing * 3) // approximate height to avoid GeometryReader collapsing
    }
}


struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 120, height: 120)
                Image(systemName: "checklist")
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)
            }

            VStack(spacing: 8) {
                Text("All Clear")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text("Add a task to start analyzing difficulty.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: - 7) HELPERS

extension String {
    func capitalizingFirstLetterIfEnglish() -> String {
        let s = self.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = s.first else { return s }
        if String(first).range(of: "[A-Za-z]", options: .regularExpression) != nil {
            return String(first).uppercased() + s.dropFirst()
        }
        return s
    }

    /// Best-effort: extract first {...} JSON object from model output.
    func extractFirstJSONObject() -> String? {
        guard let start = self.firstIndex(of: "{"),
              let end = self.lastIndex(of: "}") ,
              start <= end else { return nil }
        return String(self[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if os(macOS)
struct DisableFocusRingIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}
#endif

// MARK: - PREVIEW

private struct SeededPreviewHost: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [TodoItem]
    @State private var seeded = false

    var body: some View {
        ContentView()
            .task {
                guard !seeded else { return }
                seeded = true

                // avoid double seeding if Preview refreshes oddly
                guard items.isEmpty else { return }
                seed()
            }
    }

    @MainActor
    private func seed() {
        let cal = Calendar.current

        func dayStart(daysAgo: Int) -> Date {
            let d = cal.date(byAdding: .day, value: -daysAgo, to: Date())!
            return cal.startOfDay(for: d)
        }

        // Active tasks
        let active: [(String, Int)] = [
            ("Write proposal", 4),
            ("Refactor UI Code", 3),
            ("Buy groceries", 2)
        ]

        for (idx, a) in active.enumerated() {
            let item = TodoItem(
                title: a.0,
                difficultyScore: a.1,
                priority: 1,
                sortOrder: idx
            )
            modelContext.insert(item)
        }

        // Completed tasks: (daysAgo, count)
        let completedPlan: [(Int, Int)] = [
            (0, 3),
            (1, 1),
            (2, 2),
            (4, 5),
            (7, 1),
            (10, 3),
            (14, 2),
            (21, 4)
        ]

        for (daysAgo, count) in completedPlan {
            for i in 1...count {
                let item = TodoItem(
                    title: "Done \(i) (\(daysAgo)d ago)",
                    difficultyScore: (i % 5) + 1,
                    priority: 1,
                    isComplex: (i % 3 == 0),
                    sortOrder: nil
                )
                item.isCompleted = true

                let base = dayStart(daysAgo: daysAgo)
                item.completedAt = cal.date(byAdding: .hour, value: 9 + (i % 10), to: base)

                modelContext.insert(item)
            }
        }

        try? modelContext.save()
    }
}

#Preview {
    SeededPreviewHost()
        .modelContainer(for: TodoItem.self, inMemory: true)
}
