import SwiftUI
import AppKit

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
                        // F91 v4: use .onDrag so the NSItemProvider fires at the
                        // drag-gesture level rather than through SwiftUI's
                        // .draggable, which competes with the Button tap-target
                        // on macOS and loses before the drag threshold is met.
                        .onDrag {
                            let provider = NSItemProvider()
                            provider.registerObject(
                                FolderIDTransferNSObject(id: folder.id),
                                visibility: .ownProcess)
                            return provider
                        }
                        .dropDestination(for: ChatJIDTransfer.self) { transfers, _ in
                            for t in transfers {
                                vm.addChat(jid: t.jid, toFolderID: folder.id)
                            }
                            return !transfers.isEmpty
                        } isTargeted: { _ in
                            // visual feedback handled by FolderRailItem if needed
                        }
                        .onDrop(of: [.folderID], isTargeted: nil) { providers in
                            guard let p = providers.first else { return false }
                            p.loadDataRepresentation(
                                forTypeIdentifier: FolderIDTransfer.utTypeIdentifier
                            ) { data, _ in
                                guard let data,
                                      let payload = try? JSONDecoder().decode(
                                          FolderIDTransfer.self, from: data)
                                else { return }
                                DispatchQueue.main.async {
                                    guard
                                        let from = vm.folders.firstIndex(where: { $0.id == payload.id }),
                                        let to   = vm.folders.firstIndex(where: { $0.id == folder.id })
                                    else { return }
                                    vm.reorder(fromIndex: from, toIndex: to)
                                }
                            }
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
