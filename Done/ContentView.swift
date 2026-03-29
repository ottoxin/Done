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
    // Project / category this task belongs to (nil = uncategorized)
    var project: String?

    init(
        title: String,
        difficultyScore: Int = 1,
        priority: Int = 1,
        isComplex: Bool = false,
        sortOrder: Int? = nil,
        isToday: Bool = true,
        project: String? = nil
    ) {
        self.title = title
        self.isCompleted = false
        self.createdAt = Date()
        self.difficultyScore = difficultyScore
        self.priority = priority
        self.isComplex = isComplex
        self.sortOrder = sortOrder
        self.isToday = isToday
        self.project = project
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
            .defaultSize(width: 1120, height: 720)
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
                Image(nsImage: RadialTickRenderer.render(
                    progress: dialProgress, isActive: isLive, size: 18
                ))
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

/// Draws the radial tick dial into an NSImage (guaranteed to render in menu bar).
enum RadialTickRenderer {
    static func render(progress: Double, isActive: Bool, size: CGFloat) -> NSImage {
        let tickCount = 36
        let clamped = min(max(progress, 0), 1)
        let filled = Int((Double(tickCount) * clamped).rounded())

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let cx = size / 2, cy = size / 2
            let outerR = size / 2 - 0.5
            let innerR = outerR * 0.60

            for i in 0..<tickCount {
                let fraction = Double(i) / Double(tickCount)
                let angle = fraction * 2 * .pi - .pi / 2
                let cosA = cos(angle), sinA = sin(angle)

                let path = NSBezierPath()
                path.move(to: NSPoint(x: cx + innerR * cosA, y: cy + innerR * sinA))
                path.line(to: NSPoint(x: cx + outerR * cosA, y: cy + outerR * sinA))

                let isFilled = i < filled
                path.lineWidth = isFilled && isActive ? 2.0 : (isFilled ? 1.5 : 0.8)
                NSColor.labelColor.withAlphaComponent(isFilled ? 0.85 : 0.15).setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Radial tick-mark dial (SwiftUI shapes version — for use inside popovers / main window).
struct RadialTickView: View {
    let progress: Double   // 0.0 → 1.0
    let isActive: Bool
    private let tickCount: Int = 36

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

    // Navigation
    @State private var selectedTab: SidebarTab = .dashboard
    @State private var showChat = false
    @State private var selectedProject: String? = nil

    @ObservedObject private var calendar = CalendarService.shared
    @ObservedObject private var sharedState = SharedStateService.shared

    private func nextActiveSortOrder() -> Int {
        let today = items.filter { !$0.isCompleted && $0.isToday }
        return (today.compactMap { $0.sortOrder }.max() ?? -1) + 1
    }

    private func normalizeActiveSortOrdersIfNeeded() {
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

    /// All unique project names from tasks
    private var allProjects: [String] {
        Array(Set(items.compactMap { $0.project })).sorted()
    }

    /// Tasks completed this week
    private var completedThisWeek: Int {
        let cal = Calendar.current
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())) ?? Date()
        return items.filter {
            $0.isCompleted && ($0.completedAt ?? .distantPast) >= startOfWeek
        }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            // Icon sidebar
            iconSidebar

            // Main content
            Group {
                switch selectedTab {
                case .dashboard:
                    dashboardView
                case .tasks:
                    tasksView
                case .focus:
                    focusView
                case .schedule:
                    scheduleView
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Chat panel
            if showChat {
                Divider()
                ChatView()
                    .frame(width: 340)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showApprovalSheet) {
            TaskApprovalView(
                title: pendingTaskTitle,
                analysis: pendingAnalysis,
                projects: allProjects,
                onConfirmSingle: addSingleTask,
                onConfirmSplit: addSplitTasks
            )
            .presentationDetents([.fraction(0.5), .medium])
            .presentationCornerRadius(30)
            .presentationBackground(.ultraThinMaterial)
        }
        .onAppear {
            deepWorkToday = DeepWorkStore.countToday()
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

    // MARK: - Icon Sidebar

    enum SidebarTab: String, CaseIterable {
        case dashboard, tasks, focus, schedule, settings
    }

    private var iconSidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                sidebarIcon("square.grid.2x2", selectedIcon: "square.grid.2x2.fill", tab: .dashboard, label: "Home", badge: 0)
                sidebarIcon("checkmark.circle", selectedIcon: "checkmark.circle.fill", tab: .tasks, label: "Tasks", badge: activeTasks.count)
                sidebarIcon("hourglass", selectedIcon: "hourglass.circle.fill", tab: .focus, label: "Focus", badge: 0)
                sidebarIcon("calendar", selectedIcon: "calendar.circle.fill", tab: .schedule, label: "Schedule", badge: 0)
            }
            .padding(.top, 48)

            Spacer()

            VStack(spacing: 4) {
                // Chat toggle
                Button {
                    withAnimation(.spring(response: 0.3)) { showChat.toggle() }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: showChat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                            .font(.system(size: 16))
                            .foregroundStyle(showChat ? .blue : .secondary)
                        Text("Chat")
                            .font(.system(size: 9))
                            .foregroundStyle(showChat ? .blue : .secondary)
                    }
                    .frame(width: 52, height: 44)
                    .background(showChat ? Color.blue.opacity(0.1) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                sidebarIcon("gearshape", selectedIcon: "gearshape.fill", tab: .settings, label: "Settings", badge: 0)
            }
            .padding(.bottom, 16)
        }
        .frame(width: 68)
        .background(
            Color(NSColor.controlBackgroundColor).opacity(0.3)
        )
    }

    private func sidebarIcon(_ icon: String, selectedIcon: String, tab: SidebarTab, label: String, badge: Int) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.spring(response: 0.3)) { selectedTab = tab }
        } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: isSelected ? selectedIcon : icon)
                        .font(.system(size: 17))
                        .foregroundStyle(isSelected ? .blue : .secondary)

                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 6, y: -4)
                    }
                }
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .frame(width: 52, height: 44)
            .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Dashboard View

    private var dashboardView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Greeting
                greetingHeader
                    .padding(.horizontal, 32)
                    .padding(.top, 28)

                // Stats row — equal-width cards
                HStack(spacing: 12) {
                    statsCard(
                        title: "Weekly Tasks",
                        value: "\(completedThisWeek)",
                        subtitle: "Completed this week",
                        icon: "checkmark.circle.fill",
                        color: .green
                    )
                    .frame(maxWidth: .infinity)

                    statsCard(
                        title: "Today",
                        value: "\(activeTasks.count)",
                        subtitle: "Pending tasks",
                        icon: "list.bullet",
                        color: .blue
                    )
                    .frame(maxWidth: .infinity)

                    statsCard(
                        title: "Free Time",
                        value: calendar.totalFreeMinutesToday > 0
                            ? "\(calendar.totalFreeMinutesToday / 60)h \(calendar.totalFreeMinutesToday % 60)m"
                            : "--",
                        subtitle: "Available today",
                        icon: "clock.fill",
                        color: .teal
                    )
                    .frame(maxWidth: .infinity)

                    statsCard(
                        title: "Deep Work",
                        value: "\(deepWorkToday)",
                        subtitle: "Sessions today",
                        icon: "flame.fill",
                        color: .orange
                    )
                    .frame(maxWidth: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

                // Two-column: Tasks + Schedule
                HStack(alignment: .top, spacing: 16) {
                    // Current tasks card
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Today's Tasks")
                                .font(.headline)
                            Spacer()
                            Text("\(activeTasks.count) tasks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if activeTasks.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.green)
                                    Text("All caught up!")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 20)
                        } else {
                            ForEach(activeTasks.prefix(6)) { item in
                                dashboardTaskRow(item)
                            }
                            if activeTasks.count > 6 {
                                Text("+ \(activeTasks.count - 6) more")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 4)
                            }
                        }
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                    )

                    // Schedule + Projects column
                    VStack(spacing: 16) {
                        // Schedule card
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Schedule", systemImage: "calendar")
                                    .font(.headline)
                                Spacer()
                                if calendar.totalFreeMinutesToday > 0 {
                                    Text("\(calendar.totalFreeMinutesToday)m free")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }

                            if calendar.scheduledBlocks.isEmpty {
                                Text("No scheduled blocks yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(calendar.scheduledBlocks.prefix(4)) { block in
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(Color.blue.opacity(0.6))
                                            .frame(width: 3, height: 28)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(block.taskTitle)
                                                .font(.system(size: 12, weight: .medium))
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
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(NSColor.controlBackgroundColor))
                                .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                        )

                        // Projects card
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Projects")
                                .font(.headline)

                            if allProjects.isEmpty {
                                Text("No projects yet. Add a project when creating tasks.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(allProjects, id: \.self) { proj in
                                    let active = items.filter { $0.project == proj && !$0.isCompleted }
                                    let completed = items.filter { $0.project == proj && $0.isCompleted }
                                    let totalMins = active.map { CalendarService.shared.estimatedMinutes(for: $0) }.reduce(0, +)
                                    let completedMins = completed.map { CalendarService.shared.estimatedMinutes(for: $0) }.reduce(0, +)
                                    let color = projectColor(proj)

                                    VStack(spacing: 6) {
                                        HStack(spacing: 8) {
                                            Circle()
                                                .fill(color)
                                                .frame(width: 8, height: 8)
                                            Text(proj)
                                                .font(.system(size: 12, weight: .semibold))
                                            Spacer()
                                            Text("\(active.count) active")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }

                                        // Time bar
                                        HStack(spacing: 8) {
                                            let totalAll = totalMins + completedMins
                                            GeometryReader { geo in
                                                let fraction: CGFloat = totalAll > 0
                                                    ? CGFloat(completedMins) / CGFloat(totalAll)
                                                    : 0
                                                ZStack(alignment: .leading) {
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .fill(color.opacity(0.12))
                                                        .frame(height: 6)
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .fill(color.opacity(0.6))
                                                        .frame(width: geo.size.width * fraction, height: 6)
                                                }
                                            }
                                            .frame(height: 6)

                                            Text(formatProjectTime(completedMins + totalMins))
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(.tertiary)
                                                .frame(width: 36, alignment: .trailing)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                        .padding(20)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(NSColor.controlBackgroundColor))
                                .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                        )
                    }
                }
                .padding(.horizontal, 32)

                // Quick add
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue.opacity(0.7))

                    TextField("Quick add a task...", text: $newTaskTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .onSubmit { analyzeTask() }
                    #if os(macOS)
                        .modifier(DisableFocusRingIfAvailable())
                    #endif

                    if isAnalyzing {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.blue.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 32)

                // Momentum + Project Time
                HStack(alignment: .top, spacing: 16) {
                    // Heatmap
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Momentum")
                                .font(.headline)
                            Spacer()
                            Text("Last 4 weeks")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        HeatmapView(items: items)
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                    )
                    .frame(maxWidth: .infinity)

                    // Project time distribution
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Time by Project")
                                .font(.headline)
                            Spacer()
                            Text("14 days")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        ProjectTimeChart(items: items, projects: allProjects, projectColor: projectColor)
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
                    )
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 32)

                Color.clear.frame(height: 20)
            }
        }
    }

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(1.5)

            Text(greetingText)
                .font(.system(size: 32, weight: .bold, design: .rounded))

            if let top = activeTasks.first {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                    Text("Next up: **\(top.title)**")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    if let proj = top.project {
                        Text(proj)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(projectColor(proj))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(projectColor(proj).opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "Good morning."
        case 12..<17: return "Good afternoon."
        case 17..<22: return "Good evening."
        default:      return "Good night."
        }
    }

    private func statsCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(color.opacity(0.12)))
                Spacer()
            }

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 2)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.08), lineWidth: 1)
        )
    }

    private func dashboardTaskRow(_ item: TodoItem) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy) {
                    item.isCompleted = true
                    item.completedAt = Date()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(involvementColor(involvement(for: item.difficultyScore)).opacity(0.4), lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                    Circle()
                        .fill(involvementColor(involvement(for: item.difficultyScore)).opacity(0.08))
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let proj = item.project {
                        Text(proj)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(projectColor(proj))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(projectColor(proj).opacity(0.1))
                            .clipShape(Capsule())
                    }

                    let mins = CalendarService.shared.estimatedMinutes(for: item)
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 8))
                        Text("\(mins)m")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                    if let block = CalendarService.shared.block(for: item.id) {
                        Text(block.formattedTime)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.04))
        )
    }

    // MARK: - Tasks View

    private var tasksView: some View {
        ZStack(alignment: .bottom) {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tasks")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("\(activeTasks.count) today, \(waitlistTasks.count) someday")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Project filter
                    Menu {
                        Button("All Projects") { selectedProject = nil }
                        Divider()
                        ForEach(allProjects, id: \.self) { proj in
                            Button(proj) { selectedProject = proj }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(selectedProject ?? "All")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.gray.opacity(0.1)))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                            isFocusMode.toggle()
                            if isFocusMode { selectedTab = .focus }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                                .font(.system(size: 14, weight: .bold))
                            Text("Focus")
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.blue))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 10)

                mainList
            }

            InputBarView(
                text: $newTaskTitle,
                isAnalyzing: isAnalyzing,
                projects: allProjects,
                onCommit: analyzeTask
            )
            .padding(.bottom, 10)
        }
    }

    // MARK: - Focus View

    private var focusView: some View {
        FocusModeView(
            tasks: activeTasks,
            sessionsToday: deepWorkToday,
            onFinishSession: {
                DeepWorkStore.incrementToday()
                deepWorkToday = DeepWorkStore.countToday()
            }
        )
    }

    // MARK: - Schedule View

    private var scheduleView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Today's Schedule")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .padding(.top, 20)

                CalendarCard(calendar: calendar)

                // Queue
                if !activeTasks.isEmpty {
                    QueueCard(pending: Array(activeTasks.prefix(8)))
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Task List

    private var mainList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                let filteredActive = selectedProject == nil ? activeTasks
                    : activeTasks.filter { $0.project == selectedProject }
                let filteredWaitlist = selectedProject == nil ? waitlistTasks
                    : waitlistTasks.filter { $0.project == selectedProject }

                if filteredActive.isEmpty && filteredWaitlist.isEmpty && completedTasksByDate.isEmpty {
                    EmptyStateView().padding(.top, 40)
                } else {

                    // TODAY
                    taskSection(label: "Today", badge: filteredActive.count, tasks: filteredActive, isToday: true)

                    // SOMEDAY
                    if !filteredWaitlist.isEmpty {
                        taskSection(label: "Someday", badge: filteredWaitlist.count, tasks: filteredWaitlist, isToday: false)
                    }

                    // COMPLETED
                    if selectedProject == nil, !completedTasksByDate.isEmpty {
                        ForEach(completedTasksByDate, id: \.0) { date, tasks in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(date, format: .dateTime.month().day())
                                    .font(.subheadline).fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 24).padding(.top, 16)
                                ForEach(tasks) { item in
                                    TaskRowView(item: item, projects: allProjects, onDelete: {
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
                    Text("No tasks for today -- add one below or move one from Someday.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                }

                ForEach(tasks) { item in
                    TaskRowView(item: item, projects: allProjects, onDelete: {
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

    // MARK: - Task Actions

    private func analyzeTask() {
        let raw = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        pendingTaskTitle = raw
        newTaskTitle = ""
        isAnalyzing = true

        Task {
            let analysis = await makeLLMService().analyzeTask(title: pendingTaskTitle)

            await MainActor.run {
                if let a = analysis {
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

    // MARK: - Helpers

    func projectColor(_ name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .mint, .cyan, .red]
        return colors[stableHash(name) % colors.count]
    }

    /// Deterministic hash (djb2) — stable across app launches unlike hashValue
    private func stableHash(_ string: String) -> Int {
        var hash = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ Int(byte)
        }
        return abs(hash)
    }

    private func formatProjectTime(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h\(m)m" : "\(h)h"
        }
        return "\(minutes)m"
    }
}

// MARK: - 6) SUBVIEWS

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

// MARK: - Task Approval (with project picker)

struct TaskApprovalView: View {
    let title: String
    let analysis: TaskAnalysis?
    let projects: [String]
    var onConfirmSingle: () -> Void
    var onConfirmSplit: () -> Void

    @State private var selectedProject: String = ""
    @State private var newProjectName: String = ""

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

            // Project picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Project")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Menu {
                        Button("None") { selectedProject = "" }
                        Divider()
                        ForEach(projects, id: \.self) { proj in
                            Button(proj) { selectedProject = proj }
                        }
                        Divider()
                        Button("New Project...") { selectedProject = "__new__" }
                    } label: {
                        HStack {
                            Text(selectedProject.isEmpty ? "No project" : (selectedProject == "__new__" ? "New..." : selectedProject))
                                .font(.callout)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
                    }
                    .buttonStyle(.plain)

                    if selectedProject == "__new__" {
                        TextField("Project name", text: $newProjectName)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08)))
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

// MARK: - Sidebar Cards

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
                Text("No events today -- your day is wide open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
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
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
        )
    }
}

struct QueueCard: View {
    let pending: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next")
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
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
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

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(isCurrent ? .title3.weight(.semibold) : .body)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let proj = item.project {
                    Text(proj)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

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
    let projects: [String]
    var onDelete: () -> Void

    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @State private var isEditingProject = false
    @State private var draftProject = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var projectFocused: Bool

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

                        // Project badge (click to change/rename)
                        if let proj = item.project, !proj.isEmpty {
                            projectBadge(proj)
                        }

                        // Project picker (when no project assigned)
                        if item.project == nil || item.project?.isEmpty == true {
                            Button {
                                draftProject = ""
                                isEditingProject = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "folder.badge.plus")
                                        .font(.system(size: 9))
                                    Text("Project")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.gray.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $isEditingProject) {
                                projectPickerPopover
                            }
                        }

                        if let start = item.scheduledStart, let end = item.scheduledEnd {
                            HStack(spacing: 3) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9, weight: .medium))
                                Text("\(start, style: .time) - \(end, style: .time)")
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

    @ViewBuilder
    private func projectBadge(_ name: String) -> some View {
        let color = projectColorFor(name)
        Button {
            draftProject = name
            isEditingProject = true
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditingProject) {
            projectPickerPopover
        }
    }

    private var projectPickerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Assign Project")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // Existing projects
            if !projects.isEmpty {
                VStack(spacing: 4) {
                    ForEach(projects, id: \.self) { proj in
                        Button {
                            item.project = proj
                            isEditingProject = false
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(projectColorFor(proj))
                                    .frame(width: 8, height: 8)
                                Text(proj)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if item.project == proj {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(item.project == proj ? Color.blue.opacity(0.08) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()
            }

            // New / rename project
            HStack(spacing: 8) {
                TextField("New project name...", text: $draftProject)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($projectFocused)
                    .onSubmit {
                        let name = draftProject.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { item.project = name }
                        isEditingProject = false
                    }

                Button {
                    let name = draftProject.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { item.project = name }
                    isEditingProject = false
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(draftProject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))

            if item.project != nil {
                Button {
                    item.project = nil
                    isEditingProject = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                        Text("Remove project")
                            .font(.caption)
                    }
                    .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
            }
        }
        .padding(12)
        .frame(width: 220)
        .onAppear { projectFocused = true }
    }

    private func projectColorFor(_ name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .mint, .cyan, .red]
        var hash = 5381
        for byte in name.utf8 { hash = ((hash &<< 5) &+ hash) &+ Int(byte) }
        return colors[abs(hash) % colors.count]
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
    var projects: [String]
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            TextField("New Task...", text: $text)
                .font(.body)
                .submitLabel(.done)
                .onSubmit(onCommit)
            #if os(macOS)
                .textFieldStyle(.plain)
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
    var upNext: [TodoItem] { Array(tasks.dropFirst().prefix(4)) }

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var progress: Double {
        1.0 - Double(timeLeft) / Double(25 * 60)
    }

    private var accentGradient: LinearGradient {
        if isRunning {
            // Deep warm charcoal — calm, focused
            return LinearGradient(
                colors: [Color(red: 0.10, green: 0.10, blue: 0.12), Color(red: 0.08, green: 0.08, blue: 0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        } else {
            // Slightly lighter dark
            return LinearGradient(
                colors: [Color(red: 0.12, green: 0.12, blue: 0.14), Color(red: 0.09, green: 0.09, blue: 0.11)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    /// Muted warm accent for the progress ring
    private let ringAccent = Color(red: 0.85, green: 0.75, blue: 0.55) // warm gold
    private let ringAccentSoft = Color(red: 0.70, green: 0.62, blue: 0.45)

    private func projectColor(_ name: String) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .green, .indigo, .mint, .cyan, .red]
        var hash = 5381
        for byte in name.utf8 { hash = ((hash &<< 5) &+ hash) &+ Int(byte) }
        return colors[abs(hash) % colors.count]
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main focus area
            GeometryReader { geo in
                let ringSize: CGFloat = min(260, min(geo.size.width * 0.45, geo.size.height * 0.42))

                VStack(spacing: 0) {
                    Spacer(minLength: 20)

                    // Timer ring
                    ZStack {
                        // Track — subtle ring
                        Circle()
                            .stroke(Color.white.opacity(0.06), lineWidth: 3)
                            .frame(width: ringSize, height: ringSize)

                        // Progress arc — warm gold
                        Circle()
                            .trim(from: 0, to: CGFloat(progress))
                            .stroke(
                                ringAccent,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: timeLeft)
                            .frame(width: ringSize, height: ringSize)

                        // Soft glow at tip
                        if isRunning {
                            Circle()
                                .trim(from: max(0, CGFloat(progress) - 0.015), to: CGFloat(progress))
                                .stroke(ringAccent.opacity(0.4), lineWidth: 6)
                                .blur(radius: 6)
                                .rotationEffect(.degrees(-90))
                                .frame(width: ringSize, height: ringSize)
                        }

                        // Center content
                        VStack(spacing: 8) {
                            Text(formatTime(timeLeft))
                                .font(.system(size: ringSize * 0.26, weight: .ultraLight, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                                .contentTransition(.numericText())
                                .monospacedDigit()

                            Text(isRunning ? "FOCUSING" : (didFinishThisRun ? "COMPLETE" : "READY"))
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(4)
                                .foregroundStyle(isRunning ? ringAccent : .white.opacity(0.3))
                        }
                    }

                    Spacer().frame(height: 28)

                    // Task info
                    VStack(spacing: 10) {
                        Text(currentTask?.title ?? "No tasks pending!")
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 24)

                        if let proj = currentTask?.project {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(ringAccent.opacity(0.6))
                                    .frame(width: 5, height: 5)
                                Text(proj)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.05)))
                        }
                    }

                    Spacer().frame(height: 32)

                    // Controls
                    HStack(spacing: 28) {
                        // Reset
                        Button {
                            withAnimation(.snappy) {
                                isRunning = false
                                timeLeft = 25 * 60
                                didFinishThisRun = false
                                MenuBarState.shared.focusTimeLeft = 25 * 60
                                MenuBarState.shared.focusIsRunning = false
                            }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(.white.opacity(0.05)))
                                .overlay(Circle().stroke(.white.opacity(0.06), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        // Play/Pause
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                if !isRunning { didFinishThisRun = false }
                                isRunning.toggle()
                                MenuBarState.shared.focusIsRunning = isRunning
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(ringAccent)
                                    .frame(width: 60, height: 60)
                                    .shadow(color: ringAccent.opacity(0.2), radius: 16, y: 4)

                                Image(systemName: isRunning ? "pause.fill" : "play.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.10))
                                    .offset(x: isRunning ? 0 : 1.5)
                            }
                        }
                        .buttonStyle(.plain)

                        // Complete task
                        Button {
                            if let task = currentTask {
                                withAnimation(.snappy) {
                                    task.isCompleted = true
                                    task.completedAt = Date()
                                    isRunning = false
                                    timeLeft = 25 * 60
                                    didFinishThisRun = false
                                    MenuBarState.shared.focusTimeLeft = 25 * 60
                                    MenuBarState.shared.focusIsRunning = false
                                }
                            }
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.white.opacity(0.3))
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(.white.opacity(0.05)))
                                .overlay(Circle().stroke(.white.opacity(0.06), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Complete task")
                    }

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
            }

            // Right panel — session info + queue
            VStack(alignment: .leading, spacing: 0) {
                // Sessions header
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                        Text("Today's Sessions")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(sessionsToday)")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("sessions")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.4))
                    }

                    // Time spent today estimate
                    let minutesSpent = sessionsToday * 25
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(minutesSpent >= 60
                             ? "\(minutesSpent / 60)h \(minutesSpent % 60)m focused"
                             : "\(minutesSpent)m focused")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.35))
                }
                .padding(24)

                Divider().overlay(Color.white.opacity(0.06))

                // Up next queue
                VStack(alignment: .leading, spacing: 12) {
                    Text("UP NEXT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .tracking(1.5)

                    if upNext.isEmpty {
                        Text("This is your last task!")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.top, 4)
                    } else {
                        ForEach(upNext) { task in
                            HStack(spacing: 10) {
                                let inv = involvement(for: task.difficultyScore)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(involvementColor(inv).opacity(0.6))
                                    .frame(width: 3, height: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .lineLimit(1)

                                    HStack(spacing: 6) {
                                        if let proj = task.project {
                                            Text(proj)
                                                .font(.system(size: 9))
                                                .foregroundStyle(projectColor(proj).opacity(0.8))
                                        }
                                        let mins = CalendarService.shared.estimatedMinutes(for: task)
                                        Text("\(mins)m")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.white.opacity(0.3))
                                    }
                                }

                                Spacer()
                            }
                        }
                    }
                }
                .padding(24)

                Spacer()

                // Keyboard hints
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        keyHint("Space")
                        Text("Play / Pause")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    HStack(spacing: 6) {
                        keyHint("R")
                        Text("Reset timer")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
                .padding(24)
            }
            .frame(width: 240)
            .background(Color.white.opacity(0.03))
        }
        .background(accentGradient)
        .animation(.easeInOut(duration: 0.8), value: isRunning)
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

    private func keyHint(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.1)))
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

// MARK: - Project Time Distribution Chart

struct ProjectTimeChart: View {
    let items: [TodoItem]
    let projects: [String]
    let projectColor: (String) -> Color

    private let days = 14

    /// Compute completed minutes per project per day for the last 14 days.
    private var chartData: [(day: Int, project: String, minutes: Int)] {
        var result: [(Int, String, Int)] = []
        let cal = Calendar.current

        for dayOffset in 0..<days {
            let date = cal.date(byAdding: .day, value: -dayOffset, to: Date())!

            for proj in projects {
                let mins = items.filter { item in
                    guard item.isCompleted,
                          let completedAt = item.completedAt,
                          item.project == proj,
                          cal.isDate(completedAt, inSameDayAs: date) else { return false }
                    return true
                }.map { CalendarService.shared.estimatedMinutes(for: $0) }.reduce(0, +)

                result.append((dayOffset, proj, mins))
            }

            // "No project" bucket
            let noProj = items.filter { item in
                guard item.isCompleted,
                      let completedAt = item.completedAt,
                      (item.project == nil || item.project?.isEmpty == true),
                      cal.isDate(completedAt, inSameDayAs: date) else { return false }
                return true
            }.map { CalendarService.shared.estimatedMinutes(for: $0) }.reduce(0, +)

            if noProj > 0 {
                result.append((dayOffset, "_none", noProj))
            }
        }
        return result
    }

    /// Max daily total across all projects (for scaling).
    private var maxDailyTotal: Int {
        var totals = [Int: Int]()
        for d in chartData {
            totals[d.day, default: 0] += d.minutes
        }
        return max(totals.values.max() ?? 1, 1)
    }

    private var allProjectKeys: [String] {
        var keys = projects
        if chartData.contains(where: { $0.project == "_none" }) {
            keys.append("_none")
        }
        return keys
    }

    var body: some View {
        VStack(spacing: 12) {
            // Chart area
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let maxVal = Double(maxDailyTotal)

                ZStack(alignment: .bottomLeading) {
                    // Grid lines
                    ForEach(0..<4, id: \.self) { i in
                        let yFrac: Double = Double(i) / 3.0
                        Path { p in
                            let y = h * (1.0 - yFrac)
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(Color.gray.opacity(0.1), lineWidth: 0.5)
                    }

                    // Stacked area for each project
                    ForEach(Array(allProjectKeys.enumerated()), id: \.element) { projIdx, proj in
                        let color = proj == "_none" ? Color.gray : projectColor(proj)

                        Path { path in
                            // Build cumulative stack
                            var bottomPoints = [CGPoint]()
                            var topPoints = [CGPoint]()

                            for dayOffset in stride(from: days - 1, through: 0, by: -1) {
                                let xIdx: Double = Double(days - 1 - dayOffset)
                                let x: Double = w * xIdx / Double(max(days - 1, 1))

                                // Sum of projects below this one
                                var below: Double = 0
                                for belowIdx in 0..<projIdx {
                                    let belowProj = allProjectKeys[belowIdx]
                                    let mins = chartData.first(where: { $0.day == dayOffset && $0.project == belowProj })?.minutes ?? 0
                                    below += Double(mins)
                                }

                                let current = Double(chartData.first(where: { $0.day == dayOffset && $0.project == proj })?.minutes ?? 0)

                                let bottomY: Double = h * (1.0 - below / maxVal)
                                let topY: Double = h * (1.0 - (below + current) / maxVal)

                                bottomPoints.append(CGPoint(x: x, y: bottomY))
                                topPoints.append(CGPoint(x: x, y: topY))
                            }

                            guard !topPoints.isEmpty else { return }

                            // Draw area: top line forward, bottom line backward
                            path.move(to: topPoints[0])
                            for pt in topPoints.dropFirst() {
                                path.addLine(to: pt)
                            }
                            for pt in bottomPoints.reversed() {
                                path.addLine(to: pt)
                            }
                            path.closeSubpath()
                        }
                        .fill(
                            (proj == "_none" ? Color.gray : projectColor(proj)).opacity(0.35)
                        )

                        // Line on top
                        Path { path in
                            var topPoints = [CGPoint]()
                            for dayOffset in stride(from: days - 1, through: 0, by: -1) {
                                let xIdx: Double = Double(days - 1 - dayOffset)
                                let x: Double = w * xIdx / Double(max(days - 1, 1))
                                var below: Double = 0
                                for belowIdx in 0..<projIdx {
                                    let belowProj = allProjectKeys[belowIdx]
                                    let mins = chartData.first(where: { $0.day == dayOffset && $0.project == belowProj })?.minutes ?? 0
                                    below += Double(mins)
                                }
                                let current = Double(chartData.first(where: { $0.day == dayOffset && $0.project == proj })?.minutes ?? 0)
                                let y: Double = h * (1.0 - (below + current) / maxVal)
                                topPoints.append(CGPoint(x: x, y: y))
                            }
                            guard !topPoints.isEmpty else { return }
                            path.move(to: topPoints[0])
                            for pt in topPoints.dropFirst() {
                                path.addLine(to: pt)
                            }
                        }
                        .stroke(
                            (proj == "_none" ? Color.gray : projectColor(proj)).opacity(0.7),
                            lineWidth: 1.5
                        )
                    }

                    // X-axis labels
                    HStack {
                        Text("\(days)d ago")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("Today")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    .offset(y: 12)
                }
            }
            .frame(height: 90)

            // Legend
            let legendItems = allProjectKeys
            if !legendItems.isEmpty {
                HStack(spacing: 12) {
                    ForEach(legendItems, id: \.self) { proj in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(proj == "_none" ? Color.gray : projectColor(proj))
                                .frame(width: 6, height: 6)
                            Text(proj == "_none" ? "Other" : proj)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            // Summary
            if !projects.isEmpty {
                let totalActive = items.filter { !$0.isCompleted }.map { CalendarService.shared.estimatedMinutes(for: $0) }.reduce(0, +)
                HStack(spacing: 4) {
                    Text("Total remaining:")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(formatMins(totalActive))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func formatMins(_ m: Int) -> String {
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
}

struct HeatmapView: View {
    let items: [TodoItem]

    private let totalDays = 28
    private let barSpacing: CGFloat = 3
    private let cal = Calendar.current

    @State private var hoveredIndex: Int? = nil

    // MARK: - Data

    private func dateFor(index: Int) -> Date {
        // index 0 = 27 days ago, index 27 = today
        cal.date(byAdding: .day, value: -(totalDays - 1 - index), to: cal.startOfDay(for: Date()))!
    }

    private func completedCount(for date: Date) -> Int {
        items.filter {
            guard let completedAt = $0.completedAt else { return false }
            return cal.isDate(completedAt, inSameDayAs: date)
        }.count
    }

    private var counts: [Int] {
        (0..<totalDays).map { completedCount(for: dateFor(index: $0)) }
    }

    private var maxCount: Int { max(1, counts.max() ?? 1) }

    private var currentStreak: Int {
        var s = 0
        let today = Date()
        for offset in 0...365 {
            guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { break }
            if completedCount(for: d) > 0 { s += 1 } else { break }
        }
        return s
    }

    private var totalCompleted: Int { counts.reduce(0, +) }

    private var avgPerDay: Double {
        guard totalDays > 0 else { return 0 }
        return Double(totalCompleted) / Double(totalDays)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Inline stats row
            HStack(spacing: 16) {
                if currentStreak > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("\(currentStreak) day streak")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(Capsule())
                }

                Text("\(totalCompleted) tasks")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(String(format: "%.1f / day", avgPerDay))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Spacer()
            }

            // Bar chart — fills the full width
            GeometryReader { geo in
                let availableWidth = geo.size.width
                let barWidth = (availableWidth - barSpacing * CGFloat(totalDays - 1)) / CGFloat(totalDays)
                let chartHeight = geo.size.height

                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(0..<totalDays, id: \.self) { i in
                        let count = counts[i]
                        let d = dateFor(index: i)
                        let isFuture = d > Date()
                        let isToday = i == totalDays - 1
                        let ratio = isFuture ? 0 : (maxCount > 0 ? Double(count) / Double(maxCount) : 0)
                        let barHeight = max(isFuture ? 0 : 3, chartHeight * ratio)
                        let isWeekStart = cal.component(.weekday, from: d) == 2 // Monday

                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: max(2, barWidth * 0.3))
                                .fill(
                                    isFuture ? Color.clear :
                                    isToday ? Color.indigo :
                                    count > 0 ? Color.indigo.opacity(0.25 + ratio * 0.55) :
                                    Color.primary.opacity(0.06)
                                )
                                .frame(width: barWidth, height: barHeight)

                            // Week separator dots under Mondays
                            if isWeekStart {
                                Circle()
                                    .fill(Color.primary.opacity(0.15))
                                    .frame(width: 3, height: 3)
                            } else {
                                Spacer().frame(height: 3)
                            }
                        }
                        .onHover { hovering in
                            hoveredIndex = hovering ? i : nil
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 80)

            // Hover info / week labels row
            HStack {
                if let i = hoveredIndex {
                    let d = dateFor(index: i)
                    let count = counts[i]
                    HStack(spacing: 4) {
                        Text(d, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        Text("·")
                        Text(count == 0 ? "no tasks" : "\(count) task\(count == 1 ? "" : "s") done")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                } else {
                    // Week labels
                    HStack {
                        Text("4 weeks ago")
                        Spacer()
                        Text("2 weeks ago")
                        Spacer()
                        Text("Today")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                }
            }
        }
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

        let active: [(String, Int, String?)] = [
            ("Write proposal", 4, "Research"),
            ("Refactor UI Code", 3, "Done App"),
            ("Buy groceries", 2, nil)
        ]

        for (idx, a) in active.enumerated() {
            let item = TodoItem(
                title: a.0,
                difficultyScore: a.1,
                priority: 1,
                sortOrder: idx,
                project: a.2
            )
            modelContext.insert(item)
        }

        let completedPlan: [(Int, Int)] = [
            (0, 3), (1, 1), (2, 2), (4, 5), (7, 1), (10, 3), (14, 2), (21, 4)
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
