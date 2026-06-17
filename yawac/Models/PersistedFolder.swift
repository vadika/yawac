import Foundation
import SwiftData

/// F91: user-defined chat-grouping folder. Membership lives on
/// PersistedChat.folderIDs (Codable [String]); names are cosmetic;
/// sortIndex drives top-to-bottom order in the FolderRail.
@Model
final class PersistedFolder {
    @Attribute(.unique) var id: String
    var name: String
    var sortIndex: Int
    var createdAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         sortIndex: Int,
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}
