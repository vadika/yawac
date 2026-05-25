import Foundation

/// Tiny insertion-ordered dictionary with an LRU-by-insertion cap.
/// Setting a value moves it to the end if the key is new; existing
/// keys retain their original position. Used by ConversationViewModel
/// to stash out-of-order edits / revokes for messages we haven't
/// loaded yet.
struct OrderedDict<Key: Hashable, Value> {
    private var map: [Key: Value] = [:]
    private var order: [Key] = []
    let cap: Int

    init(cap: Int) { self.cap = cap }

    var count: Int { map.count }

    subscript(key: Key) -> Value? {
        get { map[key] }
        set {
            if let v = newValue {
                if map[key] == nil { order.append(key) }
                map[key] = v
                if order.count > cap, let oldest = order.first {
                    order.removeFirst()
                    map.removeValue(forKey: oldest)
                }
            } else {
                map.removeValue(forKey: key)
                if let idx = order.firstIndex(of: key) { order.remove(at: idx) }
            }
        }
    }

    mutating func removeValue(forKey k: Key) -> Value? {
        if let idx = order.firstIndex(of: k) { order.remove(at: idx) }
        return map.removeValue(forKey: k)
    }
}
