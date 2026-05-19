import Foundation
import Observation

@Observable @MainActor
final class GroupsViewModel {
    var groups: [BridgeGroupModel] = []
    private let client: WAClient

    init(client: WAClient) { self.client = client }

    func refresh() async {
        groups = (try? client.listGroups()) ?? []
    }
}
