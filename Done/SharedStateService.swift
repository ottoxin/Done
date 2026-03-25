import Foundation
import Combine
import SwiftData

// MARK: - Shared directory

// ~/.done/state.json   ← app writes current tasks here whenever they change
// ~/.done/updates.json ← Claude Code / Codex writes changes here; app applies + deletes

private let sharedDir: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".done")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

private let stateURL   = sharedDir.appending(path: "state.json")
private let updatesURL = sharedDir.appending(path: "updates.json")

// MARK: - Exported state (what the AI reads)

struct ExportedTask: Codable {
    var title: String
    var difficulty: Int          // 1-5
    var isComplex: Bool
    var isCompleted: Bool
    var isToday: Bool
    var sortOrder: Int
    var estimatedMinutes: Int?
    var scheduledStart: Date?
    var scheduledEnd: Date?
}

struct AppState: Codable {
    var exportedAt: Date
    var date: String             // "yyyy-MM-dd"
    var freeMinutesToday: Int
    var tasks: [ExportedTask]
}

// MARK: - Incoming update commands (what the AI writes)

struct TaskUpdate: Codable, Equatable {
    enum UpdateType: String, Codable {
        case add, complete, uncomplete, delete, reorder, reschedule, setDifficulty
    }
    var type: UpdateType
    var title: String                // used to match existing tasks
    var newTitle: String?            // for rename
    var difficulty: Int?             // for add / setDifficulty (1-5)
    var sortOrder: Int?              // for reorder (0 = top)
    var scheduledStart: String?      // ISO8601, for reschedule
    var scheduledEnd: String?        // ISO8601, for reschedule
    var isComplex: Bool?             // for add
}

struct UpdatesFile: Codable, Equatable {
    var timestamp: Date
    var message: String?             // optional note from the AI to show the user
    var changes: [TaskUpdate]
}

// MARK: - Service

@MainActor
final class SharedStateService: ObservableObject {
    static let shared = SharedStateService()

    @Published var lastAppliedMessage: String? = nil
    @Published var pendingUpdates: UpdatesFile? = nil

    private var pollTimer: Timer?
    private var lastUpdatesMTime: Date? = nil

    private init() {}

    // MARK: - Export

    func exportState(tasks: [TodoItem], freeMinutes: Int) {
        let cal = Calendar.current
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"

        let exported = tasks.map { item in
            ExportedTask(
                title: item.title,
                difficulty: item.difficultyScore,
                isComplex: item.isComplex,
                isCompleted: item.isCompleted,
                isToday: item.isToday,
                sortOrder: item.sortOrder ?? 999,
                estimatedMinutes: item.estimatedMinutes ?? CalendarService.shared.estimatedMinutes(for: item),
                scheduledStart: item.scheduledStart,
                scheduledEnd: item.scheduledEnd
            )
        }

        let state = AppState(
            exportedAt: Date(),
            date: dayFmt.string(from: Date()),
            freeMinutesToday: freeMinutes,
            tasks: exported
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: - Watch for updates (polls every 2 s)

    func startWatching() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates() }
        }
    }

    func stopWatching() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkForUpdates() {
        guard FileManager.default.fileExists(atPath: updatesURL.path) else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: updatesURL.path)
        let mtime = attrs?[.modificationDate] as? Date
        guard mtime != lastUpdatesMTime else { return }
        lastUpdatesMTime = mtime

        guard let data = try? Data(contentsOf: updatesURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(UpdatesFile.self, from: data) else {
            print("SharedStateService: could not decode updates.json")
            return
        }
        pendingUpdates = file
    }

    // MARK: - Apply updates to SwiftData

    func applyUpdates(_ file: UpdatesFile, tasks: [TodoItem], context: ModelContext) {
        let iso = ISO8601DateFormatter()

        for change in file.changes {
            switch change.type {

            case .add:
                let difficulty = max(1, min(5, change.difficulty ?? 2))
                let newOrder = (tasks.filter { !$0.isCompleted && $0.isToday }.compactMap { $0.sortOrder }.max() ?? -1) + 1
                let item = TodoItem(
                    title: change.title,
                    difficultyScore: difficulty,
                    isComplex: change.isComplex ?? false,
                    sortOrder: newOrder,
                    isToday: true
                )
                context.insert(item)

            case .complete:
                if let item = tasks.first(where: { $0.title.lowercased() == change.title.lowercased() }) {
                    item.isCompleted = true
                    item.completedAt = Date()
                }

            case .uncomplete:
                if let item = tasks.first(where: { $0.title.lowercased() == change.title.lowercased() }) {
                    item.isCompleted = false
                    item.completedAt = nil
                }

            case .delete:
                if let item = tasks.first(where: { $0.title.lowercased() == change.title.lowercased() }) {
                    context.delete(item)
                }

            case .reorder:
                if let item = tasks.first(where: { $0.title.lowercased() == change.title.lowercased() }),
                   let newOrder = change.sortOrder {
                    // Shift other tasks to make room
                    let active = tasks.filter { !$0.isCompleted && $0.id != item.id }
                        .sorted { ($0.sortOrder ?? 999) < ($1.sortOrder ?? 999) }
                    item.sortOrder = newOrder
                    for (i, t) in active.enumerated() {
                        t.sortOrder = i < newOrder ? i : i + 1
                    }
                }

            case .reschedule:
                if let item = tasks.first(where: { $0.title.lowercased() == change.title.lowercased() }) {
                    item.scheduledStart = change.scheduledStart.flatMap { iso.date(from: $0) }
                    item.scheduledEnd   = change.scheduledEnd.flatMap   { iso.date(from: $0) }
                }

            case .setDifficulty:
                if let item = tasks.first(where: { $0.title.lowercased() == change.title.lowercased() }),
                   let d = change.difficulty {
                    item.difficultyScore = max(1, min(5, d))
                }
            }
        }

        try? context.save()

        // Record message and clean up the file
        lastAppliedMessage = file.message
        try? FileManager.default.removeItem(at: updatesURL)
        pendingUpdates = nil
        lastUpdatesMTime = nil
    }

    // MARK: - Helpers

    var stateFilePath: String { stateURL.path }
    var updatesFilePath: String { updatesURL.path }
}
