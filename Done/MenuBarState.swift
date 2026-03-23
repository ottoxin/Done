import Foundation
import Combine
import SwiftData

/// Shared state that lets ContentView push live task info into the menu bar label.
final class MenuBarState: ObservableObject {
    static let shared = MenuBarState()

    @Published var currentTaskTitle: String? = nil
    @Published var currentTaskMinutes: Int? = nil
    @Published var activeCount: Int = 0
    @Published var completedToday: Int = 0

    // Block progress: 0.0 (just started) → 1.0 (block over), nil if no active block
    @Published var blockProgress: Double? = nil
    @Published var blockMinutesLeft: Int? = nil

    private var blockStart: Date? = nil
    private var blockEnd: Date? = nil
    private var ticker: AnyCancellable? = nil

    private init() {
        // Tick every 30 s to keep the progress bar live
        ticker = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refreshProgress() }
    }

    func update(tasks: [TodoItem]) {
        let active = tasks
            .filter { !$0.isCompleted && $0.isToday }
            .sorted { ($0.sortOrder ?? Int.max) < ($1.sortOrder ?? Int.max) }

        activeCount = active.count
        completedToday = tasks.filter {
            $0.isCompleted &&
            Calendar.current.isDateInToday($0.completedAt ?? .distantPast)
        }.count

        let top = active.first
        currentTaskTitle   = top?.title
        currentTaskMinutes = top.map { CalendarService.shared.estimatedMinutes(for: $0) }

        // Prefer the live CalendarService block (available as soon as scheduling runs);
        // fall back to the persisted value for when the app relaunches before a reschedule.
        if let top, let liveBlock = CalendarService.shared.block(for: top.id) {
            blockStart = liveBlock.start
            blockEnd   = liveBlock.end
        } else {
            blockStart = top?.scheduledStart
            blockEnd   = top?.scheduledEnd
        }
        refreshProgress()
    }

    private func refreshProgress() {
        guard let start = blockStart, let end = blockEnd else {
            blockProgress = nil
            blockMinutesLeft = nil
            return
        }
        let now = Date()
        guard now >= start else {
            // Block hasn't started yet
            blockProgress = 0
            blockMinutesLeft = Int(end.timeIntervalSince(now) / 60)
            return
        }
        let total   = end.timeIntervalSince(start)
        let elapsed = now.timeIntervalSince(start)
        blockProgress    = min(1.0, elapsed / total)
        blockMinutesLeft = max(0, Int(end.timeIntervalSince(now) / 60))
    }
}
