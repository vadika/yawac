import SwiftUI

struct ConversationView: View {
    let chatJID: String

    var body: some View {
        Text("Chat: \(chatJID)")
            .padding()
    }
}
