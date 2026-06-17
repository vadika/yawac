import SwiftUI

/// F91: vertical rail on the left of the chat list. Custom folders
/// on top (sorted by sortIndex), then "All chats" sentinel, then
/// "Archived" sentinel. Fixed 76pt width.
struct FolderRail: View {

    let vm: FolderRailViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(vm.folders, id: \.id) { folder in
                        FolderRailItem(
                            kind: .custom(folder),
                            isSelected: vm.selection == .custom(folderID: folder.id),
                            badge: vm.unreadByFolderID[folder.id] ?? 0,
                            onTap: { vm.selection = .custom(folderID: folder.id) })
                        .dropDestination(for: ChatJIDTransfer.self) { transfers, _ in
                            for t in transfers {
                                vm.addChat(jid: t.jid, toFolderID: folder.id)
                            }
                            return !transfers.isEmpty
                        } isTargeted: { _ in
                            // visual feedback handled by FolderRailItem if needed
                        }
                    }

                    FolderRailItem(
                        kind: .all,
                        isSelected: vm.selection == .all,
                        badge: vm.allUnread,
                        onTap: { vm.selection = .all })

                    FolderRailItem(
                        kind: .archived,
                        isSelected: vm.selection == .archived,
                        badge: vm.archivedUnread,
                        onTap: { vm.selection = .archived })
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 76)
        .background(Theme.surface)
    }
}
