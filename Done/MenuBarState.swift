import Foundation
import Combine

/// Shared state that lets ContentView push live task info into the menu bar label.
final class MenuBarState: ObservableObject {
    static let shared = MenuBarState()

    @Published var currentTaskTitle: String? = nil
    @Published var currentTaskMinutes: Int? = nil
    @Published var activeCount: Int = 0
    @Published var completedToday: Int = 0

    private init() {}

    func update(tasks: [TodoItem]) {
        let active = tasks
            .filter { !$0.isCompleted }
            .sorted { ($0.sortOrder ?? Int.max) < ($1.sortOrder ?? Int.max) }

        activeCount = active.count
        completedToday = tasks.filter {
            $0.isCompleted &&
            Calendar.current.isDateInToday($0.completedAt ?? .distantPast)
        }.count

        let top = active.first
        currentTaskTitle   = top?.title
        currentTaskMinutes = top.map { CalendarService.shared.estimatedMinutes(for: $0) }
    }
}
