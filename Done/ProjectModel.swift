import SwiftData
import SwiftUI
import Foundation

@Model
final class Project {
    @Attribute(.unique) var name: String
    var colorIndex: Int   // index into palette
    var sortOrder: Int
    var createdAt: Date

    static let palette: [Color] = [
        .blue, .purple, .orange, .teal, .pink,
        .green, .indigo, .mint, .cyan, .red
    ]

    var color: Color {
        Self.palette[colorIndex % Self.palette.count]
    }

    init(name: String, colorIndex: Int = 0, sortOrder: Int = 0) {
        self.name = name
        self.colorIndex = colorIndex
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }
}
