# Sidebar Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the placeholder "Search" hint in the chat list with a real text field that filters by name/phone and offers a bridge-validated "Start new chat" affordance for unknown numbers.

**Architecture:** New `ChatSearchViewModel` (`@Observable @MainActor`) owns the query, debounce, local filter and bridge validation. `ChatListView` consumes `filteredChats` + `suggestion` from it. `WAClient` gets a `checkOnWhatsApp(_:)` method backed by a new `bridge/contacts.go` Go function calling whatsmeow `IsOnWhatsApp`. Stub-chat creation lives on `ChatListViewModel`.

**Tech Stack:** SwiftUI, Swift Concurrency (Task, AsyncSequence), `@Observable` macro, gomobile-generated Bridge framework, Go + whatsmeow.

**Spec:** `docs/superpowers/specs/2026-05-24-sidebar-search-design.md`

---

## File Structure

| File | Role | New/Modify |
|---|---|---|
| `bridge/contacts.go` | Add `Client.CheckOnWhatsApp(phone) -> JSON` Go function | modify |
| `bridge/contacts_test.go` | Go test for new function | modify |
| `yawac/Bridge/WAClient.swift` | Add `PhoneCheckResult` + `nonisolated checkOnWhatsApp(_:)` wrapper | modify |
| `yawacTests/BridgeClientTests.swift` | JSON decode test for `PhoneCheckResult` | modify |
| `yawac/Models/PhoneSuggestion.swift` | `PhoneSuggestion` value type | new |
| `yawac/ViewModels/ChatSearchViewModel.swift` | Search state + debounce + bridge call | new |
| `yawacTests/ChatSearchViewModelTests.swift` | Unit tests for search VM | new |
| `yawac/ViewModels/ChatListViewModel.swift` | Add `upsertStubChat` | modify |
| `yawac/Views/ChatListView.swift` | Replace fake search hint, suggestion row, filter consumption | modify |
| `yawac/ContentView.swift` | Instantiate + inject `ChatSearchViewModel` | modify |

`ChatSearchViewModel` depends on `WAClient` through a narrow protocol `PhoneValidating` (defined in `WAClient.swift`) so unit tests can substitute a fake without standing up a real bridge.

---

## Task 1: Bridge — add `CheckOnWhatsApp` Go function

**Files:**
- Modify: `bridge/contacts.go`
- Test: `bridge/contacts_test.go`

- [ ] **Step 1: Write the failing test**

Append to `bridge/contacts_test.go`:

```go
func TestCheckOnWhatsAppUnpaired(t *testing.T) {
	c, err := NewClient(t.TempDir() + "/c.db")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	defer c.Close()
	// Unpaired client cannot reach the server; we only assert that the
	// method exists, returns a non-nil error or a decodable JSON shape,
	// and never panics.
	s, err := c.CheckOnWhatsApp("4915123456789")
	if err == nil {
		var got struct {
			JID          string `json:"jid"`
			Registered   bool   `json:"registered"`
			BusinessName string `json:"business_name,omitempty"`
		}
		if jerr := json.Unmarshal([]byte(s), &got); jerr != nil {
			t.Fatalf("decode: %v (%s)", jerr, s)
		}
	}
}

func TestCheckOnWhatsAppRejectsEmpty(t *testing.T) {
	c, _ := NewClient(t.TempDir() + "/c.db")
	defer c.Close()
	if _, err := c.CheckOnWhatsApp(""); err == nil {
		t.Fatalf("expected error on empty phone")
	}
}
```

- [ ] **Step 2: Run tests, expect compile failure**

```bash
cd bridge && go test -run TestCheckOnWhatsApp -v ./...
```

Expected: `undefined: (*Client).CheckOnWhatsApp` compile error.

- [ ] **Step 3: Implement `CheckOnWhatsApp`**

Append to `bridge/contacts.go`:

```go
// JPhoneCheck is the JSON-friendly view of an IsOnWhatsApp lookup result.
type JPhoneCheck struct {
	JID          string `json:"jid"`
	Registered   bool   `json:"registered"`
	BusinessName string `json:"business_name,omitempty"`
}

// CheckOnWhatsApp asks the WhatsApp server whether `phone` (E.164 digits,
// no `+`) is registered. Returns a JSON string of JPhoneCheck.
// Errors: `"rate_limited"` when the server responds with the rate-limit
// code; bridge / network errors are wrapped verbatim.
func (c *Client) CheckOnWhatsApp(phone string) (string, error) {
	if c.wa == nil {
		return "", errors.New("client closed")
	}
	if phone == "" {
		return "", errors.New("empty phone")
	}
	resp, err := c.wa.IsOnWhatsApp([]string{phone})
	if err != nil {
		// whatsmeow surfaces server rate-limit (429) as a wrapped error;
		// normalize the substring so Swift can branch on it.
		if errors.Is(err, whatsmeow.ErrIQRateOverLimit) {
			return "", errors.New("rate_limited")
		}
		return "", fmt.Errorf("is_on_whatsapp: %w", err)
	}
	if len(resp) == 0 {
		// Server accepted the query but returned nothing — treat as
		// "not registered" rather than an error.
		b, _ := json.Marshal(JPhoneCheck{Registered: false})
		return string(b), nil
	}
	r := resp[0]
	out := JPhoneCheck{
		JID:          r.JID.String(),
		Registered:   r.IsIn,
		BusinessName: r.VerifiedName.GetDetails().GetVerifiedName(),
	}
	b, _ := json.Marshal(out)
	return string(b), nil
}
```

Then add the whatsmeow import if not already present:

```go
import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"go.mau.fi/whatsmeow"
)
```

- [ ] **Step 4: Run tests, expect pass**

```bash
cd bridge && go test -run TestCheckOnWhatsApp -v ./...
```

Expected: both new tests PASS. (`TestCheckOnWhatsAppUnpaired` may skip-ish: when `IsOnWhatsApp` returns a network error on an unpaired client, that's fine — the test only asserts no panic and decodable JSON when err is nil.)

- [ ] **Step 5: Run full bridge test suite**

```bash
cd bridge && go test -short ./...
```

Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add bridge/contacts.go bridge/contacts_test.go
git commit -m "feat(bridge): add CheckOnWhatsApp via whatsmeow IsOnWhatsApp"
```

---

## Task 2: Rebuild `Bridge.xcframework`

**Files:**
- Modify: `build/Bridge.xcframework` (generated)

- [ ] **Step 1: Rebuild xcframework**

```bash
./scripts/build-xcframework.sh
```

Expected output: `Built: build/Bridge.xcframework` (5–15 min first run, much faster on incremental).

- [ ] **Step 2: Verify the new symbol surfaced**

```bash
grep -l "checkOnWhatsApp" build/Bridge.xcframework/macos-*/Bridge.framework/Versions/A/Headers/*.h
```

Expected: at least one matching header path (gomobile camel-cases `CheckOnWhatsApp` → `checkOnWhatsApp`).

- [ ] **Step 3: Commit the rebuilt framework** (only if it's tracked in this repo; check first)

```bash
git status -s build/
```

If `build/` is gitignored (likely — check `.gitignore`), skip the commit. Otherwise:

```bash
git add build/Bridge.xcframework
git commit -m "chore(bridge): rebuild xcframework with CheckOnWhatsApp"
```

---

## Task 3: Swift — `PhoneCheckResult` + `checkOnWhatsApp` on `WAClient`

**Files:**
- Modify: `yawac/Bridge/WAClient.swift`
- Test: `yawacTests/BridgeClientTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `yawacTests/BridgeClientTests.swift`:

```swift
func testDecodePhoneCheckResultRegistered() throws {
    let json = #"""
    {"jid":"4915123456789@s.whatsapp.net","registered":true}
    """#
    let r = try JSONDecoder().decode(PhoneCheckResult.self, from: Data(json.utf8))
    XCTAssertEqual(r.jid, "4915123456789@s.whatsapp.net")
    XCTAssertTrue(r.registered)
    XCTAssertNil(r.businessName)
}

func testDecodePhoneCheckResultNotRegistered() throws {
    let json = #"{"jid":"","registered":false}"#
    let r = try JSONDecoder().decode(PhoneCheckResult.self, from: Data(json.utf8))
    XCTAssertFalse(r.registered)
}

func testDecodePhoneCheckResultBusiness() throws {
    let json = #"""
    {"jid":"49123@s.whatsapp.net","registered":true,"business_name":"Acme"}
    """#
    let r = try JSONDecoder().decode(PhoneCheckResult.self, from: Data(json.utf8))
    XCTAssertEqual(r.businessName, "Acme")
}
```

- [ ] **Step 2: Run, expect fail**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test -only-testing:yawacTests/BridgeClientTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: compile error `cannot find 'PhoneCheckResult' in scope`.

- [ ] **Step 3: Implement `PhoneCheckResult` and `checkOnWhatsApp`**

In `yawac/Bridge/WAClient.swift`, add this `struct` at the top level of the file (outside the class, alongside other top-level types):

```swift
struct PhoneCheckResult: Decodable, Equatable {
    let jid: String
    let registered: Bool
    let businessName: String?

    enum CodingKeys: String, CodingKey {
        case jid, registered
        case businessName = "business_name"
    }
}

protocol PhoneValidating: AnyObject {
    var ownJID: String { get }
    /// Synchronous — call from off-main via `Task.detached`.
    func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult
}
```

Inside `final class WAClient`, add after `func listContacts()`:

```swift
nonisolated func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult {
    var err: NSError?
    let json = go.checkOnWhatsApp(phone, error: &err)
    if let err { throw err }
    return try JSONDecoder().decode(PhoneCheckResult.self, from: Data(json.utf8))
}
```

Make `WAClient` conform to `PhoneValidating` by adding the protocol to the class declaration:

```swift
@MainActor
final class WAClient: PhoneValidating {
```

(`ownJID` already exists; the new `checkOnWhatsApp` is `nonisolated` and satisfies the protocol requirement.)

- [ ] **Step 4: Run tests, expect pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test -only-testing:yawacTests/BridgeClientTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: all `BridgeClientTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/Bridge/WAClient.swift yawacTests/BridgeClientTests.swift
git commit -m "feat(bridge): expose checkOnWhatsApp + PhoneCheckResult in WAClient"
```

---

## Task 4: `PhoneSuggestion` value type

**Files:**
- Create: `yawac/Models/PhoneSuggestion.swift`

- [ ] **Step 1: Create the file**

`yawac/Models/PhoneSuggestion.swift`:

```swift
import Foundation

struct PhoneSuggestion: Equatable, Identifiable {
    let jid: String
    let displayPhone: String
    var id: String { jid }
}
```

- [ ] **Step 2: Build, expect success**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add yawac/Models/PhoneSuggestion.swift
git commit -m "feat(models): add PhoneSuggestion value type"
```

---

## Task 5: `ChatSearchViewModel` — skeleton + empty-query pass-through

**Files:**
- Create: `yawac/ViewModels/ChatSearchViewModel.swift`
- Create: `yawacTests/ChatSearchViewModelTests.swift`

- [ ] **Step 1: Create skeleton file**

`yawac/ViewModels/ChatSearchViewModel.swift`:

```swift
import Foundation
import Observation

@Observable @MainActor
final class ChatSearchViewModel {
    var query: String = "" {
        didSet { onQueryChanged() }
    }
    private(set) var filteredChats: [Chat] = []
    private(set) var suggestion: PhoneSuggestion? = nil
    private(set) var validating: Bool = false

    private weak var listVM: ChatListViewModel?
    private let validator: PhoneValidating
    private var debounceTask: Task<Void, Never>? = nil

    /// Debounce interval before running the filter / firing bridge validation.
    /// Exposed for tests so they don't have to sleep 500ms.
    var debounceMs: Int = 500

    init(listVM: ChatListViewModel, validator: PhoneValidating) {
        self.listVM = listVM
        self.validator = validator
        self.filteredChats = listVM.chats
    }

    func clear() {
        debounceTask?.cancel()
        query = ""
        suggestion = nil
        validating = false
        filteredChats = listVM?.chats ?? []
    }

    private func onQueryChanged() {
        debounceTask?.cancel()
        let q = query
        if q.isEmpty {
            filteredChats = listVM?.chats ?? []
            suggestion = nil
            validating = false
            return
        }
        debounceTask = Task { [weak self, debounceMs] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard let self, !Task.isCancelled else { return }
            await self.runFilter(q)
        }
    }

    private func runFilter(_ q: String) async {
        // Implemented in Task 6.
        filteredChats = listVM?.chats ?? []
    }
}
```

- [ ] **Step 2: Write the failing test**

`yawacTests/ChatSearchViewModelTests.swift`:

```swift
import XCTest
@testable import yawac

@MainActor
final class ChatSearchViewModelTests: XCTestCase {

    // MARK: - Test fixtures

    final class FakeValidator: PhoneValidating {
        var ownJID: String = ""
        var stub: Result<PhoneCheckResult, Error> = .success(
            PhoneCheckResult(jid: "", registered: false, businessName: nil))
        var calls: [String] = []

        func checkOnWhatsApp(_ phone: String) throws -> PhoneCheckResult {
            calls.append(phone)
            switch stub {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }

    private func makeListVM(chats: [Chat] = []) -> ChatListViewModel {
        // Use the gomobile-free path: WAClient is needed for the init
        // signature, so we go through a lightweight test seam — see
        // helper below.
        let vm = ChatListViewModelTestHarness.make()
        vm.chats = chats
        return vm
    }

    private func makeChat(jid: String, name: String) -> Chat {
        Chat(jid: jid, name: name, lastMessage: "", lastTimestamp: 0, unread: 0)
    }

    // MARK: - Tests

    func testEmptyQueryPassesThroughAllChats() {
        let list = makeListVM(chats: [
            makeChat(jid: "1@s.whatsapp.net", name: "Alice"),
            makeChat(jid: "2@s.whatsapp.net", name: "Bob"),
        ])
        let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
        XCTAssertEqual(search.filteredChats.count, 2)
        XCTAssertNil(search.suggestion)
    }

    func testSettingThenClearingQueryRestoresAllChats() async {
        let list = makeListVM(chats: [
            makeChat(jid: "1@s.whatsapp.net", name: "Alice"),
        ])
        let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
        search.debounceMs = 1
        search.query = "x"
        try? await Task.sleep(for: .milliseconds(10))
        search.query = ""
        XCTAssertEqual(search.filteredChats.count, 1)
        XCTAssertNil(search.suggestion)
    }
}
```

- [ ] **Step 3: Make `ChatListViewModel.client` optional and add test harness**

Tests need a `ChatListViewModel` without the gomobile bridge. Loosen `client` to optional.

In `yawac/ViewModels/ChatListViewModel.swift`, change the stored property and initializer:

```swift
private let client: WAClient?
// ...
init(client: WAClient?, context: ModelContext? = nil) {
    self.client = client
    self.context = context
    loadChats()
}
```

Update the one site that calls a method on `client` directly. In `loadChats()`, change:

```swift
let canon = client.resolveLIDToPN(r.jid)
```

to:

```swift
let canon = client?.resolveLIDToPN(r.jid) ?? r.jid
```

Every other internal site already passes `client: client` to `JIDNormalize.canonical`, which accepts `WAClient?` — no further changes needed.

Append the harness to `yawacTests/ChatSearchViewModelTests.swift`:

```swift
@MainActor
enum ChatListViewModelTestHarness {
    static func make() -> ChatListViewModel {
        ChatListViewModel(client: nil, context: nil)
    }
}
```

Production callsite in `ContentView.swift` (Task 11) already passes a non-nil client, so behavior is unchanged at runtime.

- [ ] **Step 4: Run tests, expect fail (skeleton runFilter returns all chats — pass-through tests should pass; filter tests in later tasks will fail later)**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test -only-testing:yawacTests/ChatSearchViewModelTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: both `testEmptyQueryPassesThroughAllChats` and `testSettingThenClearingQueryRestoresAllChats` PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ChatSearchViewModel.swift \
        yawac/ViewModels/ChatListViewModel.swift \
        yawacTests/ChatSearchViewModelTests.swift
git commit -m "feat(search): ChatSearchViewModel skeleton + pass-through"
```

---

## Task 6: Local name + digit filter

**Files:**
- Modify: `yawac/ViewModels/ChatSearchViewModel.swift`
- Modify: `yawacTests/ChatSearchViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `ChatSearchViewModelTests.swift`:

```swift
func testFiltersByCaseInsensitiveNameSubstring() async {
    let list = makeListVM(chats: [
        makeChat(jid: "1@s.whatsapp.net", name: "Alice Smith"),
        makeChat(jid: "2@s.whatsapp.net", name: "Bob Jones"),
        makeChat(jid: "3@s.whatsapp.net", name: "Carol Smith"),
    ])
    let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
    search.debounceMs = 1
    search.query = "smith"
    try? await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(Set(search.filteredChats.map(\.jid)),
                   Set(["1@s.whatsapp.net", "3@s.whatsapp.net"]))
}

func testFiltersByDigitSubstringAcrossJIDFormats() async {
    let list = makeListVM(chats: [
        makeChat(jid: "4915123456789@s.whatsapp.net", name: "Alice"),
        makeChat(jid: "4915999999999@s.whatsapp.net", name: "Bob"),
    ])
    let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
    search.debounceMs = 1
    search.query = "+49 151 2345"
    try? await Task.sleep(for: .milliseconds(10))
    XCTAssertEqual(search.filteredChats.map(\.jid),
                   ["4915123456789@s.whatsapp.net"])
}

func testFilterReturnsEmptyOnNoMatch() async {
    let list = makeListVM(chats: [
        makeChat(jid: "1@s.whatsapp.net", name: "Alice"),
    ])
    let search = ChatSearchViewModel(listVM: list, validator: FakeValidator())
    search.debounceMs = 1
    search.query = "zzzz"
    try? await Task.sleep(for: .milliseconds(10))
    XCTAssertTrue(search.filteredChats.isEmpty)
}
```

- [ ] **Step 2: Run, expect fail**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test -only-testing:yawacTests/ChatSearchViewModelTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: the three new tests FAIL (skeleton still returns all chats).

- [ ] **Step 3: Implement filter**

Replace the placeholder `runFilter` in `ChatSearchViewModel.swift`:

```swift
private func runFilter(_ q: String) async {
    let normalized = q.trimmingCharacters(in: .whitespacesAndNewlines)
                       .lowercased()
    let digits = Self.digitsOnly(q)
    let source = listVM?.chats ?? []
    let matches = source.filter { chat in
        if chat.name.localizedCaseInsensitiveContains(normalized) {
            return true
        }
        if !digits.isEmpty, Self.digitsOnly(chat.jid).contains(digits) {
            return true
        }
        return false
    }
    self.filteredChats = matches
}

private static func digitsOnly(_ s: String) -> String {
    String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
}
```

- [ ] **Step 4: Run, expect pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test -only-testing:yawacTests/ChatSearchViewModelTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: all `ChatSearchViewModelTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ChatSearchViewModel.swift \
        yawacTests/ChatSearchViewModelTests.swift
git commit -m "feat(search): local name + digit substring filter"
```

---

## Task 7: Phone heuristic + bridge validation (with suggestion)

**Files:**
- Modify: `yawac/ViewModels/ChatSearchViewModel.swift`
- Modify: `yawacTests/ChatSearchViewModelTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `ChatSearchViewModelTests.swift`:

```swift
func testPhoneHeuristicAcceptsPlusForm() {
    XCTAssertTrue(ChatSearchViewModel.looksLikePhone("+491"))
    XCTAssertTrue(ChatSearchViewModel.looksLikePhone("+49 151 234 56 78"))
}

func testPhoneHeuristicAcceptsSevenPlusDigits() {
    XCTAssertTrue(ChatSearchViewModel.looksLikePhone("1234567"))
    XCTAssertTrue(ChatSearchViewModel.looksLikePhone("4915123456789"))
}

func testPhoneHeuristicRejectsShortDigits() {
    XCTAssertFalse(ChatSearchViewModel.looksLikePhone("12345"))
}

func testPhoneHeuristicRejectsLetters() {
    XCTAssertFalse(ChatSearchViewModel.looksLikePhone("hello"))
    XCTAssertFalse(ChatSearchViewModel.looksLikePhone("alice123"))
}

func testValidationFiresForUnknownPhone() async {
    let list = makeListVM(chats: [])
    let v = FakeValidator()
    v.stub = .success(PhoneCheckResult(
        jid: "4915123456789@s.whatsapp.net",
        registered: true, businessName: nil))
    let search = ChatSearchViewModel(listVM: list, validator: v)
    search.debounceMs = 1
    search.query = "+49 151 2345 678"
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(v.calls, ["4915123456789"])
    XCTAssertEqual(search.suggestion?.jid, "4915123456789@s.whatsapp.net")
}

func testValidationSkippedWhenChatAlreadyMatches() async {
    let list = makeListVM(chats: [
        makeChat(jid: "4915123456789@s.whatsapp.net", name: "Alice"),
    ])
    let v = FakeValidator()
    let search = ChatSearchViewModel(listVM: list, validator: v)
    search.debounceMs = 1
    search.query = "+49 151 2345 6789"
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(v.calls.isEmpty)
    XCTAssertNil(search.suggestion)
}

func testValidationDoesNotFireForNonPhoneQuery() async {
    let list = makeListVM(chats: [])
    let v = FakeValidator()
    let search = ChatSearchViewModel(listVM: list, validator: v)
    search.debounceMs = 1
    search.query = "hello"
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(v.calls.isEmpty)
}

func testValidationSuppressesSelfJID() async {
    let list = makeListVM(chats: [])
    let v = FakeValidator()
    v.ownJID = "4915123456789@s.whatsapp.net"
    v.stub = .success(PhoneCheckResult(
        jid: "4915123456789@s.whatsapp.net",
        registered: true, businessName: nil))
    let search = ChatSearchViewModel(listVM: list, validator: v)
    search.debounceMs = 1
    search.query = "+4915123456789"
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(search.suggestion)
}

func testValidationClearsSuggestionWhenNotRegistered() async {
    let list = makeListVM(chats: [])
    let v = FakeValidator()
    v.stub = .success(PhoneCheckResult(jid: "", registered: false, businessName: nil))
    let search = ChatSearchViewModel(listVM: list, validator: v)
    search.debounceMs = 1
    search.query = "+4915999999999"
    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertNil(search.suggestion)
}

func testValidationDebouncesRapidQueryChanges() async {
    let list = makeListVM(chats: [])
    let v = FakeValidator()
    v.stub = .success(PhoneCheckResult(
        jid: "4915123456788@s.whatsapp.net",
        registered: true, businessName: nil))
    let search = ChatSearchViewModel(listVM: list, validator: v)
    search.debounceMs = 20
    search.query = "+491512345678"
    search.query = "+4915123456788"
    try? await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(v.calls.count, 1)
    XCTAssertEqual(v.calls.first, "4915123456788")
}
```

- [ ] **Step 2: Run, expect fail**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test -only-testing:yawacTests/ChatSearchViewModelTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: heuristic tests fail with `cannot find 'looksLikePhone'`; validation tests fail because no bridge call is made yet.

- [ ] **Step 3: Implement heuristic + validation**

In `ChatSearchViewModel.swift`, replace the body of `onQueryChanged()` and append `maybeValidate` + `looksLikePhone`:

```swift
private func onQueryChanged() {
    debounceTask?.cancel()
    let q = query
    if q.isEmpty {
        filteredChats = listVM?.chats ?? []
        suggestion = nil
        validating = false
        return
    }
    debounceTask = Task { [weak self, debounceMs] in
        try? await Task.sleep(for: .milliseconds(debounceMs))
        guard let self, !Task.isCancelled else { return }
        await self.runFilter(q)
        await self.maybeValidate(q)
    }
}

private func maybeValidate(_ q: String) async {
    guard Self.looksLikePhone(q) else {
        suggestion = nil
        return
    }
    let digits = Self.digitsOnly(q)
    // Skip if an existing chat already matches by digits — user
    // already has that conversation.
    if let chats = listVM?.chats,
       chats.contains(where: { Self.digitsOnly($0.jid).contains(digits) }) {
        suggestion = nil
        return
    }
    validating = true
    suggestion = nil
    let validator = self.validator
    let result: PhoneCheckResult?
    do {
        result = try await Task.detached(priority: .userInitiated) {
            try validator.checkOnWhatsApp(digits)
        }.value
    } catch {
        NSLog("[yawac/search] checkOnWhatsApp failed: %@", String(describing: error))
        result = nil
    }
    guard !Task.isCancelled else { return }
    validating = false
    guard let r = result, r.registered else {
        suggestion = nil
        return
    }
    if !validator.ownJID.isEmpty, r.jid == validator.ownJID {
        suggestion = nil
        return
    }
    suggestion = PhoneSuggestion(
        jid: r.jid,
        displayPhone: "+" + digits)
}

static func looksLikePhone(_ s: String) -> Bool {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return false }
    let digits = digitsOnly(trimmed)
    // Any non-digit char that isn't whitespace, `+`, `-`, `(`, `)` disqualifies.
    let allowed = CharacterSet(charactersIn: "+-() ").union(.decimalDigits)
                                                    .union(.whitespaces)
    if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
        return false
    }
    if trimmed.hasPrefix("+") { return digits.count >= 1 }
    return digits.count >= 7
}
```

Change the visibility of `digitsOnly` from `private` to `internal` so `looksLikePhone` can call it as a static — actually both are static, keep them both `static`. Update the signature in Task 6 if needed:

```swift
static func digitsOnly(_ s: String) -> String {
    String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
}
```

- [ ] **Step 4: Run, expect pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test -only-testing:yawacTests/ChatSearchViewModelTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: all `ChatSearchViewModelTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ChatSearchViewModel.swift \
        yawacTests/ChatSearchViewModelTests.swift
git commit -m "feat(search): bridge-validated phone suggestion"
```

---

## Task 8: `ChatListViewModel.upsertStubChat`

**Files:**
- Modify: `yawac/ViewModels/ChatListViewModel.swift`
- Modify: `yawacTests/ChatSearchViewModelTests.swift` (add coverage)

- [ ] **Step 1: Write failing test**

Append to `ChatSearchViewModelTests.swift`:

```swift
func testUpsertStubChatAddsNewRow() {
    let vm = ChatListViewModelTestHarness.make()
    let id = vm.upsertStubChat(jid: "499@s.whatsapp.net", displayName: "+499")
    XCTAssertEqual(id, "499@s.whatsapp.net")
    XCTAssertEqual(vm.chats.count, 1)
    XCTAssertEqual(vm.chats.first?.jid, "499@s.whatsapp.net")
    XCTAssertEqual(vm.chats.first?.name, "+499")
}

func testUpsertStubChatIsIdempotent() {
    let vm = ChatListViewModelTestHarness.make()
    let existing = Chat(
        jid: "499@s.whatsapp.net", name: "Alice",
        lastMessage: "hi", lastTimestamp: 100, unread: 0)
    vm.chats = [existing]
    let id = vm.upsertStubChat(jid: "499@s.whatsapp.net", displayName: "+499")
    XCTAssertEqual(id, "499@s.whatsapp.net")
    XCTAssertEqual(vm.chats.count, 1)
    XCTAssertEqual(vm.chats.first?.name, "Alice", "should NOT overwrite real name")
    XCTAssertEqual(vm.chats.first?.lastMessage, "hi")
}
```

- [ ] **Step 2: Run, expect fail**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test -only-testing:yawacTests/ChatSearchViewModelTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: compile error `cannot find 'upsertStubChat'`.

- [ ] **Step 3: Implement `upsertStubChat`**

In `yawac/ViewModels/ChatListViewModel.swift`, add inside the class (e.g. right after `func markRead`):

```swift
/// Insert a placeholder chat for a JID that isn't yet known locally
/// (typically because the user just searched for an unknown phone
/// number and tapped the "Start chat" suggestion). Idempotent: if a
/// row for `jid` already exists, returns its id without touching it.
@discardableResult
func upsertStubChat(jid: String, displayName: String) -> Chat.ID {
    if let existing = chats.first(where: { $0.jid == jid }) {
        return existing.id
    }
    let chat = Chat(
        jid: jid,
        name: displayName,
        lastMessage: "",
        lastTimestamp: Int64(Date().timeIntervalSince1970),
        unread: 0)
    chats.append(chat)
    sortChats()
    upsertPersisted(chat)
    return chat.id
}
```

- [ ] **Step 4: Run, expect pass**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test -only-testing:yawacTests/ChatSearchViewModelTests \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: both new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add yawac/ViewModels/ChatListViewModel.swift \
        yawacTests/ChatSearchViewModelTests.swift
git commit -m "feat(chat): add ChatListViewModel.upsertStubChat for new-chat flow"
```

---

## Task 9: `ChatListView` — real search field + ⌘K focus

**Files:**
- Modify: `yawac/Views/ChatListView.swift`

- [ ] **Step 1: Add search field, focus state, environment**

In `yawac/Views/ChatListView.swift`, at the top of `struct ChatListView`, add:

```swift
@Environment(ChatSearchViewModel.self) private var search
@FocusState private var searchFocused: Bool
```

Replace the block at lines 105–131 (the fake search hint) with:

```swift
// ─── Real search field. ⌘K focuses; empty query restores full list.
HStack(spacing: 8) {
    Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.textFaint)
    TextField("Search", text: Bindable(search).query)
        .textFieldStyle(.plain)
        .font(Theme.ui(12.5))
        .foregroundStyle(Theme.textMain)
        .focused($searchFocused)
        .onSubmit { searchFocused = false }
    if search.validating {
        ProgressView().controlSize(.small)
    } else if !search.query.isEmpty {
        Button {
            search.clear()
            searchFocused = false
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Theme.textFaint)
        }
        .buttonStyle(.plain)
    } else {
        Text("⌘K")
            .font(Theme.mono(10.5))
            .foregroundStyle(Theme.textFaint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}
.padding(.horizontal, 10).padding(.vertical, 7)
.background(Theme.surface)
.overlay(
    RoundedRectangle(cornerRadius: 8)
        .stroke(searchFocused ? Theme.accent : Theme.border,
                lineWidth: 1)
)
.clipShape(RoundedRectangle(cornerRadius: 8))
.padding(.horizontal, 14)
.padding(.bottom, 8)
.background(
    // Hidden button receives ⌘K and forwards focus to the field.
    Button("") { searchFocused = true }
        .keyboardShortcut("k", modifiers: .command)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
)
```

(Note: `Bindable(search).query` requires `import SwiftUI` at the top — already imported.)

- [ ] **Step 2: Build**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED. (The view will not render in-app yet because `ChatSearchViewModel` isn't injected — Task 11 wires that up. Don't worry that the preview/runtime would crash here; we'll do the wiring before runtime smoke.)

- [ ] **Step 3: Commit**

```bash
git add yawac/Views/ChatListView.swift
git commit -m "feat(ui): real search field with cmd-K focus in ChatListView"
```

---

## Task 10: `ChatListView` — suggestion row + filtered displayRows

**Files:**
- Modify: `yawac/Views/ChatListView.swift`

- [ ] **Step 1: Add `suggestion` Row variant and source selection**

In `yawac/Views/ChatListView.swift`, modify the `Row` enum (around line 32–41):

```swift
private enum Row: Hashable, Identifiable {
    case section(id: String, label: String, count: Int)
    case chat(Chat, indent: CGFloat)
    case suggestion(PhoneSuggestion)
    var id: String {
        switch self {
        case .section(let id, _, _): return "sec:" + id
        case .chat(let c, let i):    return "row:\(c.jid)#\(Int(i))"
        case .suggestion(let s):     return "sug:" + s.jid
        }
    }
}
```

Modify `displayRows()` to consume the filtered source and prepend a suggestion row when present. Replace the first line of `displayRows()`:

```swift
private func displayRows() -> [Row] {
    let chats = search.query.isEmpty ? vm.chats : search.filteredChats
    var out: [Row] = []
    if let s = search.suggestion {
        out.append(.suggestion(s))
    }
    // (existing logic continues, using `chats` as before)
    var communities: [Chat] = []
    // ...
```

The rest of `displayRows()` stays unchanged but appends its results into `out` instead of starting fresh. Concretely, replace `var out: [Row] = []` (currently the line right after the for-loop that bucketises chats) with no-op since `out` is now declared above. If the existing body declares `out` again, remove that re-declaration.

Final shape of `displayRows()`:

```swift
private func displayRows() -> [Row] {
    let chats = search.query.isEmpty ? vm.chats : search.filteredChats
    var out: [Row] = []
    if let s = search.suggestion {
        out.append(.suggestion(s))
    }

    var communities: [Chat] = []
    var standaloneGroups: [Chat] = []
    var directChats: [Chat] = []
    var subsByParent: [String: [Chat]] = [:]
    for c in chats {
        if c.isCommunityParent {
            communities.append(c)
        } else if let parent = c.communityParentJID, !parent.isEmpty {
            subsByParent[parent, default: []].append(c)
        } else if c.isGroup {
            standaloneGroups.append(c)
        } else {
            directChats.append(c)
        }
    }

    let s = scope
    if (s == .all || s == .communities) && !communities.isEmpty {
        out.append(.section(id: "channels", label: "Channels", count: communities.count))
        for parent in communities {
            out.append(.chat(parent, indent: 0))
            for sub in subsByParent[parent.jid] ?? [] {
                out.append(.chat(sub, indent: 16))
            }
        }
    }
    if (s == .all || s == .groups) && !standaloneGroups.isEmpty {
        out.append(.section(id: "groups", label: "Groups", count: standaloneGroups.count))
        for g in standaloneGroups { out.append(.chat(g, indent: 0)) }
    }
    if (s == .all || s == .chats) && !directChats.isEmpty {
        out.append(.section(id: "direct", label: "Direct", count: directChats.count))
        for c in directChats { out.append(.chat(c, indent: 0)) }
    }
    return out
}
```

- [ ] **Step 2: Add suggestion row rendering + tap handler**

Modify the `ForEach(displayRows())` switch (around line 171–177):

```swift
ForEach(displayRows()) { row in
    switch row {
    case .section(_, let label, let count):
        sectionLabel(label, count: count)
    case .chat(let chat, let indent):
        chatRowButton(chat, indent: indent)
    case .suggestion(let s):
        suggestionRowButton(s)
    }
}
```

Add the helper method on `ChatListView`:

```swift
@ViewBuilder
private func suggestionRowButton(_ s: PhoneSuggestion) -> some View {
    Button {
        let id = vm.upsertStubChat(jid: s.jid, displayName: s.displayPhone)
        selection = id
        search.clear()
    } label: {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(Theme.accentText)
                .frame(width: 32, height: 32)
                .background(Theme.accentSoft,
                            in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(s.displayPhone)
                    .font(Theme.ui(13, weight: .medium))
                    .foregroundStyle(Theme.textMain)
                Text("Start new chat")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.textFaint)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' build \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add yawac/Views/ChatListView.swift
git commit -m "feat(ui): suggestion row + filtered displayRows in ChatListView"
```

---

## Task 11: `ContentView` — instantiate and inject `ChatSearchViewModel`

**Files:**
- Modify: `yawac/ContentView.swift`

- [ ] **Step 1: Add `@State` and inject env**

In `ContentView`, add:

```swift
@State private var chatSearch: ChatSearchViewModel?
```

In the `NavigationSplitView` sidebar, change:

```swift
if let chatList {
    ChatListView(selection: $selectedChat)
        .environment(chatList)
}
```

to:

```swift
if let chatList, let chatSearch {
    ChatListView(selection: $selectedChat)
        .environment(chatList)
        .environment(chatSearch)
} else {
    ProgressView()
}
```

(Remove the standalone `} else { ProgressView() }` branch from the original — the combined `if let` covers it.)

In `.task`, right after `self.chatList = vm`, add:

```swift
self.chatSearch = ChatSearchViewModel(listVM: vm, validator: client)
```

- [ ] **Step 2: Build + run unit tests**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' \
  test \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

Expected: BUILD SUCCEEDED, all tests PASS.

- [ ] **Step 3: Commit**

```bash
git add yawac/ContentView.swift
git commit -m "feat(app): wire ChatSearchViewModel into ContentView"
```

---

## Task 12: Manual smoke

**Files:** none (verification only)

- [ ] **Step 1: Launch app**

```bash
xcodebuild -project yawac.xcodeproj -scheme yawac \
  -destination 'platform=macOS' build \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
open build/DerivedData/Build/Products/Debug/yawac.app
```

- [ ] **Step 2: Verify name filter**

1. Type a partial contact name (e.g. "ali") in the sidebar search field.
2. Expected: list narrows to chats whose names contain "ali" (case-insensitive). Sections collapse when empty.

- [ ] **Step 3: Verify digit filter against existing chat**

1. Type the first 6+ digits of an existing contact's phone.
2. Expected: list narrows to that chat. No "Start chat" suggestion row.

- [ ] **Step 4: Verify suggestion for unknown phone**

1. Clear the field. Type a valid WhatsApp number that is NOT in your contacts (e.g. a colleague's). Use `+` form.
2. Expected: after ~500ms, a spinner appears briefly, then a row "Start new chat" + the number appears above the (empty) chat list.

- [ ] **Step 5: Verify self-number suppression**

1. Clear the field. Type your own WhatsApp number.
2. Expected: no suggestion row.

- [ ] **Step 6: Verify suggestion tap opens conversation**

1. Repeat step 4. Tap the suggestion row.
2. Expected: `ConversationView` opens against the new JID with an empty message list. The sidebar search clears and the new chat appears in the Direct section.

- [ ] **Step 7: Verify ⌘K**

1. Click into the chat area (de-focus the search field).
2. Press ⌘K.
3. Expected: caret appears in the search field.

- [ ] **Step 8: Verify Esc/clear**

1. With non-empty query, click the `x` button in the field.
2. Expected: query clears, full chat list restored.

- [ ] **Step 9: Commit if any tweaks were needed**

If steps surfaced any small fixes, commit them and re-run from the failing step.

---

## Notes for the executor

- **gomobile rebuild time:** the first `./scripts/build-xcframework.sh` after touching `bridge/*.go` can take 5–15 minutes. Incremental rebuilds are much faster.
- **Build product paths:** the project uses `xcodegen` to generate `yawac.xcodeproj`. If `project.yml` changes, run `xcodegen generate` first. For these tasks, no `project.yml` changes are needed.
- **Test isolation:** `ChatListViewModelTestHarness.make()` constructs a `ChatListViewModel` with `client: nil` and `context: nil`; both are now optional after Task 5. Production wiring (`ContentView.task`) always passes real values, so this only affects test code paths.
- **whatsmeow error type:** `whatsmeow.ErrIQRateOverLimit` is what current whatsmeow exposes (verify in `bridge/go.sum` / IDE). If a different symbol is canonical at HEAD, swap accordingly — the test only asserts on the `"rate_limited"` error string.
