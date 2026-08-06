import EventKit
import Foundation
import Combine
import SwiftUI
import SwiftData

// MARK: - Data types

struct CalendarEvent: Identifiable {
    let id = UUID()
    let title: String
    let start: Date
    let end: Date
}

struct FreeTimeSlot: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var durationMinutes: Int { Int(duration / 60) }

    var formattedRange: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }
}

struct ScheduledTaskBlock: Identifiable {
    let id = UUID()
    let taskID: PersistentIdentifier
    let taskTitle: String
    let start: Date
    let end: Date

    var formattedTime: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return "\(f.string(from: start)) – \(f.string(from: end))"
    }

    var durationMinutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

// MARK: - Calendar Service

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    private let store = EKEventStore()

    @Published var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published var todayFreeSlots: [FreeTimeSlot] = []
    @Published var scheduledBlocks: [ScheduledTaskBlock] = []
    @Published var busyEvents: [CalendarEvent] = []

    private init() {}

    var isAuthorized: Bool {
        if #available(macOS 14.0, *) {
            return authorizationStatus == .fullAccess
        } else {
            return authorizationStatus == .authorized
        }
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var totalFreeMinutesToday: Int {
        Int(todayFreeSlots.reduce(0) { $0 + $1.duration } / 60)
    }

    // MARK: - Access

    func requestAccessIfNeeded() async {
        let current = EKEventStore.authorizationStatus(for: .event)
        authorizationStatus = current
        guard !isAuthorized else {
            await refreshToday()
            return
        }
        if #available(macOS 14.0, *) {
            _ = try? await store.requestFullAccessToEvents()
        } else {
            await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { _, _ in cont.resume() }
            }
        }
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if isAuthorized { await refreshToday() }
    }

    // MARK: - Fetch

    func refreshToday() async {
        let cal = Calendar.current
        let now = Date()
        let startOfDay = cal.startOfDay(for: now)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else { return }

        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        busyEvents = events.map { CalendarEvent(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate) }

        // Work window: now → 10 PM
        let workEnd = cal.date(bySettingHour: 22, minute: 0, second: 0, of: now) ?? endOfDay
        todayFreeSlots = computeFreeSlots(events: events, from: now, to: min(workEnd, endOfDay))
    }

    private func computeFreeSlots(events: [EKEvent], from start: Date, to end: Date) -> [FreeTimeSlot] {
        var slots: [FreeTimeSlot] = []
        var cursor = start

        for event in events {
            guard event.endDate > cursor, event.startDate < end else { continue }
            let gapEnd = min(event.startDate, end)
            if gapEnd.timeIntervalSince(cursor) >= 15 * 60 {
                slots.append(FreeTimeSlot(start: cursor, end: gapEnd))
            }
            cursor = max(cursor, event.endDate)
        }
        if end.timeIntervalSince(cursor) >= 15 * 60 {
            slots.append(FreeTimeSlot(start: cursor, end: end))
        }
        return slots
    }

    // MARK: - Scheduling

    /// Assign time blocks to tasks with time-of-day preference, inter-block buffer,
    /// and a 80% cap on total free time so the schedule isn't suffocating.
    func scheduleTasks(_ tasks: [TodoItem]) {
        guard !todayFreeSlots.isEmpty, !tasks.isEmpty else {
            scheduledBlocks = []
            return
        }

        let cal = Calendar.current
        let now = Date()
        // "Morning" = anything before noon today
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        let bufferSeconds: TimeInterval = 5 * 60   // 5-min gap between blocks

        // Cap: use at most 80% of total free time so there's breathing room
        let totalFree = todayFreeSlots.reduce(0) { $0 + $1.duration }
        let cap = totalFree * 0.80

        // Split free slots into morning / afternoon pools (mutable working copies)
        var morningPool = todayFreeSlots.filter { $0.start < noon }
        var afternoonPool = todayFreeSlots.filter { $0.start >= noon }

        var blocks: [ScheduledTaskBlock] = []
        var totalUsed: TimeInterval = 0

        // Returns true if the block was placed
        @discardableResult
        func place(_ task: TodoItem, into pool: inout [FreeTimeSlot]) -> Bool {
            let needed = TimeInterval(estimatedMinutes(for: task) * 60)
            // Fit the task whole or not at all. Shrinking it to whatever is left
            // under the cap produced blocks that contradicted the task's own
            // estimate — a 60-minute task could show up as a 2-minute block.
            guard needed >= 60, totalUsed + needed <= cap else { return false }

            for i in pool.indices {
                let available = pool[i].end.timeIntervalSince(pool[i].start)
                guard available >= needed else { continue }

                let blockStart = pool[i].start
                let blockEnd   = blockStart.addingTimeInterval(needed)
                blocks.append(ScheduledTaskBlock(
                    taskID: task.id,
                    taskTitle: task.title,
                    start: blockStart,
                    end: blockEnd
                ))
                totalUsed += needed

                // Advance the slot past this block + buffer
                let newStart = blockEnd.addingTimeInterval(bufferSeconds)
                if newStart < pool[i].end {
                    pool[i] = FreeTimeSlot(start: newStart, end: pool[i].end)
                } else {
                    pool.remove(at: i)
                }
                return true
            }
            return false
        }

        // Schedule tasks in user's sort order (top = highest priority).
        // Heavy tasks (≥ 3) prefer morning; light tasks prefer afternoon — but
        // user priority always wins over time-of-day preference.
        for task in tasks {
            let prefersmorning = task.difficultyScore >= 3
            if prefersmorning {
                if !place(task, into: &morningPool) { place(task, into: &afternoonPool) }
            } else {
                if !place(task, into: &afternoonPool) { place(task, into: &morningPool) }
            }
        }

        scheduledBlocks = blocks.sorted { $0.start < $1.start }
    }

    func block(for taskID: PersistentIdentifier) -> ScheduledTaskBlock? {
        scheduledBlocks.first { $0.taskID == taskID }
    }

    // MARK: - Estimation (AI value preferred; difficulty is the fallback)

    func estimatedMinutes(for task: TodoItem) -> Int {
        if let ai = task.estimatedMinutes, ai > 0 { return ai }
        return heuristicMinutes(title: task.title, difficulty: task.difficultyScore)
    }

    /// Keyword-based estimate used when the AI hasn't analysed the task yet.
    private func heuristicMinutes(title: String, difficulty: Int) -> Int {
        let lower = title.lowercased()
        let heavy  = ["write", "draft", "design", "build", "implement", "develop", "create",
                      "refactor", "research", "plan", "prepare", "architect", "analyze", "analyse",
                      "document", "thesis", "dissertation", "essay", "paper", "report", "proposal",
                      "presentation", "slides", "clustering", "classification", "training",
                      "model", "algorithm", "pipeline", "project", "assignment", "homework",
                      "study", "learn", "coding", "program", "migrate", "integrate", "deploy"]
        let medium = ["review", "update", "fix", "edit", "check", "test", "read",
                      "call", "meet", "debug", "interview", "discuss", "explore",
                      "setup", "configure", "install", "organize", "sort", "clean",
                      "outline", "brainstorm", "draft"]
        let quick  = ["reply", "email", "message", "buy", "schedule", "book",
                      "confirm", "approve", "ping", "send", "submit", "share",
                      "print", "sign", "pay", "order", "lookup"]

        let isHeavy  = heavy.contains  { lower.contains($0) }
        let isMedium = !isHeavy  && medium.contains { lower.contains($0) }
        let isQuick  = !isHeavy  && !isMedium && quick.contains { lower.contains($0) }

        switch difficulty {
        case 5: return 90
        case 4: return isHeavy ? 75 : 60
        case 3: return isHeavy ? 60 : isMedium ? 45 : 35
        case 2: return isHeavy ? 45 : isMedium ? 30 : isQuick ? 15 : 25
        case 1: return isHeavy ? 30 : isQuick ? 8 : isMedium ? 18 : 20
        default:
            if isHeavy  { return 45 }
            if isMedium { return 30 }
            if isQuick  { return 10 }
            return 25
        }
    }
}
