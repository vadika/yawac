import Foundation
import Bridge

/// Bridges Go's `EventSink` protocol to a Swift `AsyncStream`.
/// gomobile generates the Objective-C `BridgeEventSink` protocol with selector
/// `onEvent:jsonPayload:`. We adopt it on this NSObject subclass.
/// Note: the framework declares both a `BridgeEventSink` protocol AND a class
/// (see `Bridge.objc.h`). We adopt the protocol via its fully-qualified
/// `BridgeEventSinkProtocol` name to avoid the class-vs-protocol ambiguity.
final class WAEventBus: NSObject, BridgeEventSinkProtocol {
    let stream: AsyncStream<(kind: String, payload: String)>
    private let continuation: AsyncStream<(kind: String, payload: String)>.Continuation

    override init() {
        var c: AsyncStream<(kind: String, payload: String)>.Continuation!
        self.stream = AsyncStream { c = $0 }
        self.continuation = c
        super.init()
    }

    func onEvent(_ eventType: String?, jsonPayload: String?) {
        guard let kind = eventType, let payload = jsonPayload else { return }
        continuation.yield((kind, payload))
    }
}
