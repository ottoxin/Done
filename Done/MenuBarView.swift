import SwiftUI
import SwiftData

// MARK: - Main menu bar panel

struct MenuBarTaskView: View {
    @Query private var allItems: [TodoItem]
    @ObservedObject private var calendar = CalendarService.shared

    private var activeTasks: [TodoItem] {
        allItems
            .filter { !$0.isCompleted }
            .sorted { ($0.sortOrder ?? Int.max) < ($1.sortOrder ?? Int.max) }
    }

    private var completedToday: Int {
        allItems.filter {
            $0.isCompleted && Calendar.current.isDateInToday($0.completedAt ?? .distantPast)
        }.count
    }

    private var currentTask: TodoItem? { activeTasks.first }

    var body: some View {
        VStack(spacing: 0) {
            // ── Now card ──────────────────────────────
            nowCard

            // ── Timeline of remaining blocks ──────────
            if !calendar.scheduledBlocks.isEmpty || activeTasks.count > 1 {
                Divider()
                upcomingStrip
            }

            // ── Footer ────────────────────────────────
            Divider()
            footerBar
        }
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Now card

    @ViewBuilder
    private var nowCard: some View {
        if let task = currentTask {
            VStack(alignment: .leading, spacing: 0) {
                // Label row
                HStack {
                    Label("NOW", systemImage: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .tracking(1.5)

                    Spacer()

                    // Progress dots
                    HStack(spacing: 4) {
                        ForEach(0..<min(activeTasks.count, 5), id: \.self) { i in
                            Circle()
                                .fill(i == 0 ? Color.white : Color.white.opacity(0.3))
                                .frame(width: 5, height: 5)
                        }
                        if activeTasks.count > 5 {
                            Text("+\(activeTasks.count - 5)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)

                // Task title
                Text(task.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 14)

                // Meta row
                HStack(spacing: 10) {
                    let mins = CalendarService.shared.estimatedMinutes(for: task)
                    Label("\(mins)m", systemImage: "clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                    if let block = calendar.block(for: task.id) {
                        Label(block.formattedTime, systemImage: "calendar")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    Spacer()

                    let inv = involvement(for: task.difficultyScore)
                    Text(inv == .high ? "High" : "Low")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.2)))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }
            .background(
                LinearGradient(
                    colors: [accentColor(for: task), accentColor(for: task).opacity(0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        } else {
            // All done
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All done today!")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    if completedToday > 0 {
                        Text("\(completedToday) task\(completedToday == 1 ? "" : "s") completed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(14)
        }
    }

    // MARK: Upcoming strip

    private var upcomingStrip: some View {
        VStack(spacing: 0) {
            HStack {
                Text("UP NEXT")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(1.5)
                Spacer()
                if calendar.totalFreeMinutesToday > 0 {
                    Text("\(calendar.totalFreeMinutesToday)m free")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            // Show remaining tasks (skip the first — that's "now")
            ForEach(activeTasks.dropFirst().prefix(5)) { task in
                upcomingRow(task)
                if task.id != activeTasks.dropFirst().prefix(5).last?.id {
                    Divider().padding(.leading, 14)
                }
            }
        }
    }

    private func upcomingRow(_ task: TodoItem) -> some View {
        HStack(spacing: 10) {
            // Difficulty bar
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor(for: task).opacity(0.6))
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    let mins = CalendarService.shared.estimatedMinutes(for: task)
                    Text("\(mins)m")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if let block = calendar.block(for: task.id) {
                        Text("·")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 10))
                        Text(block.formattedTime)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Footer

    private var footerBar: some View {
        HStack(spacing: 0) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { !$0.isFloatingPanel })?.makeKeyAndOrderFront(nil)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Spacer()

            // Completed today badge
            if completedToday > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 10))
                    Text("\(completedToday) today")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
            }

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
    }

    // MARK: Helpers

    private func accentColor(for task: TodoItem) -> Color {
        switch task.difficultyScore {
        case 4...5: return .orange
        case 3:     return .blue
        default:    return .teal
        }
    }
}
