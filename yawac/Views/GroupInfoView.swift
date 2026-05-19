import SwiftUI

struct GroupInfoView: View {
    let group: BridgeGroupModel

    var body: some View {
        Form {
            Section {
                Text(group.name).font(.title)
                if !group.topic.isEmpty {
                    Text(group.topic).foregroundStyle(.secondary)
                }
            }
            Section("Participants (\(group.participants.count))") {
                ForEach(group.participants, id: \.jid) { p in
                    HStack {
                        Text(p.jid)
                        Spacer()
                        if p.isSuper {
                            Text("super").foregroundStyle(.purple)
                        } else if p.isAdmin {
                            Text("admin").foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
        .padding()
    }
}
