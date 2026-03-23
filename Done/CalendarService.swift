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

        // Heavy tasks (difficulty ≥ 3) prefer mornings; light ones prefer afternoons
        let heavy = tasks.filter { $0.difficultyScore >= 3 }
        let light  = tasks.filter { $0.difficultyScore < 3 }

        var blocks: [ScheduledTaskBlock] = []
        var totalUsed: TimeInterval = 0

        // Returns true if the block was placed
        @discardableResult
        func place(_ task: TodoItem, into pool: inout [FreeTimeSlot]) -> Bool {
            guard totalUsed < cap else { return false }
            let needed = TimeInterval(estimatedMinutes(for: task) * 60)
            let remaining = min(needed, cap - totalUsed)
            guard remaining >= 60 else { return false } // don't schedule < 1 min

            for i in pool.indices {
                let available = pool[i].end.timeIntervalSince(pool[i].start)
                guard available >= remaining else { continue }

                let blockStart = pool[i].start
                let blockEnd   = blockStart.addingTimeInterval(remaining)
                blocks.append(ScheduledTaskBlock(
                    taskID: task.id,
                    taskTitle: task.title,
                    start: blockStart,
                    end: blockEnd
                ))
                totalUsed += remaining

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

        // Schedule heavy tasks: morning first, spill into afternoon
        for task in heavy {
            if !place(task, into: &morningPool) {
                place(task, into: &afternoonPool)
            }
        }
        // Schedule light tasks: afternoon first, spill into morning
        for task in light {
            if !place(task, into: &afternoonPool) {
                place(task, into: &morningPool)
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
        switch task.difficultyScore {
        case 1: return 15
        case 2: return 25
        case 3: return 45
        case 4: return 60
        case 5: return 90
        default: return 30
        }
    }
}
