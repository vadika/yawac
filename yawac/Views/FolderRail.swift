import SwiftUI

/// F91: vertical rail on the left of the chat list. Custom folders
/// on top (sorted by sortIndex), then "All chats" sentinel, then
/// "Archived" sentinel. Fixed 76pt width.
struct FolderRail: View {

    enum Event {
        case rename(PersistedFolder)
        case delete(PersistedFolder)
        case newFolder(insertIndex: Int)
    }

    let vm: FolderRailViewModel
    let onEvent: (Event) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(vm.folders.enumerated()), id: \.element.id) { idx, folder in
                        FolderRailItem(
                            kind: .custom(folder),
                            isSelected: vm.selection == .custom(folderID: folder.id),
                            badge: vm.unreadByFolderID[folder.id] ?? 0,
                            onTap: { vm.selection = .custom(folderID: folder.id) })
                        .draggable(FolderIDTransfer(id: folder.id)) {
                            FolderRailItem(kind: .custom(folder),
                                           isSelected: true,
                                           badge: 0,
                                           onTap: {})
                                .opacity(0.6)
                        }
                        .dropDestination(for: ChatJIDTransfer.self) { transfers, _ in
                            for t in transfers {
                                vm.addChat(jid: t.jid, toFolderID: folder.id)
                            }
                            return !transfers.isEmpty
                        } isTargeted: { _ in
                            // visual feedback handled by FolderRailItem if needed
                        }
                        .dropDestination(for: FolderIDTransfer.self) { transfers, _ in
                            guard let moved = transfers.first,
                                  let from = vm.folders.firstIndex(where: { $0.id == moved.id }),
                                  let to = vm.folders.firstIndex(where: { $0.id == folder.id })
                            else { return false }
                            vm.reorder(fromIndex: from, toIndex: to)
                            return true
                        }
                        .contextMenu {
                            Button("Rename…") { onEvent(.rename(folder)) }
                            Button("Delete folder…", role: .destructive) {
                                onEvent(.delete(folder))
                            }
                            Divider()
                            Button("New folder…") {
                                onEvent(.newFolder(insertIndex: vm.folders.count))
                            }
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

                    Button {
                        onEvent(.newFolder(insertIndex: vm.folders.count))
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus")
                                .scaledIcon(16, weight: .semibold)
                                .foregroundStyle(Theme.textFaint)
                                .frame(width: 44, height: 36)
                                .background(Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                            Text("New")
                                .scaledUI(10.5)
                                .foregroundStyle(Theme.textFaint)
                        }
                        .frame(width: 72)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New folder…")
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 76)
        .background(Theme.surface)
    }
}
