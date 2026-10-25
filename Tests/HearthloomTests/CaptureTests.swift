import XCTest
@testable import Hearthloom

final class CaptureTests: XCTestCase {
    private var queue: CaptureQueue!
    private var fileURL: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-tests-\(UUID().uuidString)/queue.json")
        queue = CaptureQueue(fileURL: fileURL)
        defaults = UserDefaults(suiteName: "capture.tests")!
        defaults.removePersistentDomain(forName: "capture.tests")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    private func item(_ ref: String, _ text: String = "a thought") -> CaptureItem {
        CaptureItem(clientRef: ref, text: text, capturedAt: Date(timeIntervalSince1970: 1_784_849_400))
    }

    private let ok = HearthAPI.CaptureReply(kind: "note", id: "nt_1", duplicate: false)

    // MARK: - Queue

    func testAppendPersistsInOrderAcrossInstances() throws {
        try queue.append(item("a"))
        try queue.append(item("b"))
        XCTAssertEqual(CaptureQueue(fileURL: fileURL).all().map(\.clientRef), ["a", "b"])
    }

    func testAppendDedupesByClientRef() throws {
        try queue.append(item("a", "first"))
        try queue.append(item("a", "second"))
        XCTAssertEqual(queue.all().map(\.text), ["first"])
    }

    func testRemoveOnlyRemovesThatItem() throws {
        try queue.append(item("a")); try queue.append(item("b"))
        queue.remove(clientRef: "a")
        XCTAssertEqual(queue.all().map(\.clientRef), ["b"])
    }

    func testQueueFileIsReadableAfterFirstUnlock() throws {
        try queue.append(item("a"))
        let protection = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.protectionKey] as? FileProtectionType
        // The simulator doesn't enforce data protection and may report nil.
        if let protection { XCTAssertEqual(protection, .completeUntilFirstUserAuthentication) }
    }

    // MARK: - Drain

    func testDrainUploadsEverythingOldestFirst() async throws {
        try queue.append(item("a")); try queue.append(item("b"))
        var sent: [String] = []
        let result = await CaptureDrain.run(queue: queue) { sent.append($0.clientRef); return self.ok }
        XCTAssertEqual(sent, ["a", "b"])
        XCTAssertEqual(result, CaptureDrainResult(uploaded: 2))
        XCTAssertTrue(queue.all().isEmpty)
    }

    func testDrainRemovesServerSideDuplicate() async throws {
        try queue.append(item("a"))
        let result = await CaptureDrain.run(queue: queue) { _ in
            HearthAPI.CaptureReply(kind: "task", id: "tk_1", duplicate: true)
        }
        XCTAssertEqual(result.uploaded, 1)
        XCTAssertTrue(queue.all().isEmpty)
    }

    func testDrainDropsA400AndCarriesOn() async throws {
        try queue.append(item("bad")); try queue.append(item("good"))
        let result = await CaptureDrain.run(queue: queue) { item in
            if item.clientRef == "bad" { throw HearthAPI.CaptureError.rejected("nothing to capture") }
            return self.ok
        }
        XCTAssertEqual(result, CaptureDrainResult(uploaded: 1, dropped: 1, dropReason: "nothing to capture"))
        XCTAssertTrue(queue.all().isEmpty)
    }

    func testDrainKeepsItemsOnEveryRetryableFailure() async throws {
        let failures: [HearthAPI.CaptureError] =
            [.unauthorized, .endpointUnavailable, .rateLimited, .transient("server error 503")]
        for failure in failures {
            let q = CaptureQueue(fileURL: fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(UUID().uuidString).json"))
            try q.append(item("a")); try q.append(item("b"))
            var calls = 0
            let result = await CaptureDrain.run(queue: q) { _ in calls += 1; throw failure }
            XCTAssertEqual(result.stoppedBy, failure)
            XCTAssertEqual(result.uploaded, 0)
            XCTAssertEqual(calls, 1, "stops at the first failure rather than hammering the node")
            XCTAssertEqual(q.all().map(\.clientRef), ["a", "b"], "\(failure) must keep the queue intact")
        }
    }

    func testDrainKeepsItemsOnUnexpectedError() async throws {
        try queue.append(item("a"))
        let result = await CaptureDrain.run(queue: queue) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertNotNil(result.stoppedBy)
        XCTAssertEqual(queue.count, 1)
    }

    func testRetryAfterFailureUploadsExactlyOnce() async throws {
        try queue.append(item("a"))
        _ = await CaptureDrain.run(queue: queue) { _ in throw HearthAPI.CaptureError.transient("offline") }
        var sent: [String] = []
        _ = await CaptureDrain.run(queue: queue) { sent.append($0.clientRef); return self.ok }
        _ = await CaptureDrain.run(queue: queue) { sent.append($0.clientRef); return self.ok }
        XCTAssertEqual(sent, ["a"], "same client_ref, sent once after the network returns")
    }

    func testRaceStopsWaitingButLetsTheWorkFinish() async {
        let finished = expectation(description: "slow work still completes")
        let started = Date()
        let slow: Int? = await Race.first(within: 0.2) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            finished.fulfill()
            return 1
        }
        XCTAssertNil(slow)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8)
        let fast: Int? = await Race.first(within: 2) { 2 }
        XCTAssertEqual(fast, 2)
        await fulfillment(of: [finished], timeout: 3)
    }

    func testBackoffDoublesAndCaps() {
        XCTAssertEqual(CaptureDrain.backoff(failures: 1), 30)
        XCTAssertEqual(CaptureDrain.backoff(failures: 2), 60)
        XCTAssertEqual(CaptureDrain.backoff(failures: 30), 3600)
    }

    // MARK: - Status

    func testStatusRecordsSuccess() {
        let status = CaptureStatus(defaults: defaults)
        status.keyRejected = true; status.endpointUnavailable = true; status.failures = 3
        let now = Date(timeIntervalSince1970: 2000)
        status.record(CaptureDrainResult(uploaded: 2), now: now)
        XCTAssertEqual(status.uploadedCount, 2)
        XCTAssertEqual(status.lastUploadAt, now)
        XCTAssertFalse(status.keyRejected)
        XCTAssertFalse(status.endpointUnavailable)
        XCTAssertEqual(status.failures, 0)
        XCTAssertNil(status.nextAttemptAt)
    }

    func testStatusRecordsRejectedKeyUnavailableAndBackoff() {
        let status = CaptureStatus(defaults: defaults)
        let now = Date(timeIntervalSince1970: 2000)

        status.record(CaptureDrainResult(stoppedBy: .unauthorized), now: now)
        XCTAssertTrue(status.keyRejected)

        status.record(CaptureDrainResult(stoppedBy: .endpointUnavailable), now: now)
        XCTAssertTrue(status.endpointUnavailable)
        XCTAssertEqual(status.nextAttemptAt, now.addingTimeInterval(CaptureIngestConfig.unavailableRetry))

        status.record(CaptureDrainResult(stoppedBy: .transient("x")), now: now)
        status.record(CaptureDrainResult(stoppedBy: .rateLimited), now: now)
        XCTAssertEqual(status.failures, 2)
        XCTAssertEqual(status.nextAttemptAt, now.addingTimeInterval(60))

        status.record(CaptureDrainResult(dropped: 1, dropReason: "too long"), now: now)
        XCTAssertEqual(status.lastDropped, "too long")
    }

    // MARK: - Request encoding

    func testPayloadCarriesContractFieldsAndLetsTheServerPickKind() {
        let body = CapturePayload.build(item: item("ref-1", "buy oat milk"))
        XCTAssertEqual(body["text"] as? String, "buy oat milk")
        XCTAssertEqual(body["client_ref"] as? String, "ref-1")
        XCTAssertEqual(body["captured_at"] as? String, "2026-07-23T23:30:00Z")
        XCTAssertEqual(body["device"] as? String, "iPhone")
        XCTAssertNil(body["kind"], "auto is the server default; never send a kind the user didn't choose")
        XCTAssertNil(body["lat"]); XCTAssertNil(body["lon"])
    }

    func testPayloadIncludesLocationOnlyWhenBothPresent() {
        var located = item("a"); located.lat = 12.5; located.lon = -34.5
        let body = CapturePayload.build(item: located)
        XCTAssertEqual(body["lat"] as? Double, 12.5)
        XCTAssertEqual(body["lon"] as? Double, -34.5)

        var half = item("b"); half.lat = 12.5
        XCTAssertNil(CapturePayload.build(item: half)["lat"])
    }

    func testCaptureRequest() throws {
        let api = HearthAPI(baseURL: URL(string: "https://node.example.com")!)
        let req = try api.captureRequest(token: "hl_abc", item: item("ref-1"))
        XCTAssertEqual(req.url?.absoluteString, "https://node.example.com/v1/ingest/capture")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer hl_abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["client_ref"] as? String, "ref-1")
    }

    func testStatusCodeMapping() {
        typealias E = HearthAPI.CaptureError
        XCTAssertEqual(E.from(status: 400, message: "nothing to capture"), .rejected("nothing to capture"))
        XCTAssertEqual(E.from(status: 401, message: nil), .unauthorized)
        XCTAssertEqual(E.from(status: 403, message: nil), .unauthorized)
        XCTAssertEqual(E.from(status: 404, message: nil), .endpointUnavailable)
        XCTAssertEqual(E.from(status: 429, message: nil), .rateLimited)
        XCTAssertEqual(E.from(status: 503, message: nil), .transient("server error 503"))
    }

    func testValidateTrimsAndRejectsEmptyAndTooLong() throws {
        XCTAssertEqual(try CaptureService.validate("  call Ada \n"), "call Ada")
        XCTAssertThrowsError(try CaptureService.validate(" \n ")) { XCTAssertEqual($0 as? CaptureInputError, .empty) }
        XCTAssertNoThrow(try CaptureService.validate(String(repeating: "x", count: 8000)))
        XCTAssertThrowsError(try CaptureService.validate(String(repeating: "x", count: 8001))) {
            XCTAssertEqual($0 as? CaptureInputError, .tooLong)
        }
    }

    // MARK: - Capture key

    func testCaptureKeyBodyUsesGrantsAndNoScopes() {
        let body = HearthAPI.captureKeyBody(deviceName: "Test iPhone")
        XCTAssertEqual(body["actor"] as? String, "adapter:ios-capture")
        XCTAssertEqual(body["name"] as? String, "iphone-capture-test-iphone")
        let grants = body["grants"] as? [String: Any]
        XCTAssertEqual(grants?["capture"] as? Bool, true)
        XCTAssertEqual(grants?["own_device"] as? Bool, true, "captures are the owner's own words")
        XCTAssertEqual(grants?.count, 2, "nothing beyond capture + own_device")
        XCTAssertNil(body["scopes"], "sending scopes with grants is a 400")
    }

    func testOnlyACaptureOnlyKeyIsAccepted() {
        func reply(grants: [String: Any]?, scopes: [String] = []) -> [String: Any] {
            ["secret": "hl_x", "key": ["scopes": scopes, "grants": grants as Any]]
        }
        let captureOnly: [String: Any] = ["capture": true, "tasks": "none", "notes": "none", "memory": "none", "ask": false]
        XCTAssertTrue(HearthAPI.isCaptureOnlyKey(reply(grants: captureOnly)))
        XCTAssertFalse(HearthAPI.isCaptureOnlyKey(reply(grants: nil, scopes: ["read"])), "an ordinary key")
        XCTAssertFalse(HearthAPI.isCaptureOnlyKey(reply(grants: captureOnly, scopes: ["read"])))
        var readsNotes = captureOnly; readsNotes["notes"] = "read"
        XCTAssertFalse(HearthAPI.isCaptureOnlyKey(reply(grants: readsNotes)))
        var asks = captureOnly; asks["ask"] = true
        XCTAssertFalse(HearthAPI.isCaptureOnlyKey(reply(grants: asks)))
    }

    /// The node echoes every grant field back, including `own_device` — which
    /// widens nothing, so the key is still capture-only.
    func testAnOwnDeviceCaptureKeyIsStillCaptureOnly() {
        let echoed: [String: Any] = ["capture": true, "own_device": true, "tasks": "none",
                                     "notes": "none", "memory": "none", "ask": false,
                                     "writes_per_hour": NSNull(), "asks_per_day": NSNull(),
                                     "areas": NSNull()]
        let reply: [String: Any] = ["secret": "hl_x", "key": ["scopes": [String](), "grants": echoed]]
        XCTAssertTrue(HearthAPI.isCaptureOnlyKey(reply))

        var writesNotes = echoed; writesNotes["notes"] = "write"
        XCTAssertFalse(HearthAPI.isCaptureOnlyKey(["secret": "hl_x",
                                                   "key": ["scopes": [String](), "grants": writesNotes]]),
                       "own_device doesn't excuse a broader grant")
    }

    func testIntentConfirmationNeverCarriesContent() {
        // The three possible replies are fixed strings — nothing from the capture.
        _ = CaptureToHearthloomIntent.confirmation(queued: 0, keyRejected: false)
        _ = CaptureToHearthloomIntent.confirmation(queued: 2, keyRejected: true)
        _ = CaptureToHearthloomIntent.confirmation(queued: 2, keyRejected: false)
    }

    /// The host app's RootView consumes the request itself (and opens the
    /// sheet), so only the announcement is asserted here; the sheet is covered
    /// by CaptureControlUITests.
    func testOpenCaptureIntentAnnouncesTheRequest() async throws {
        let asked = expectation(forNotification: CaptureLaunch.requested, object: nil)
        _ = try await OpenCaptureIntent().perform()
        await fulfillment(of: [asked], timeout: 2)
    }

    // MARK: - Live (opt-in)

    /// End-to-end against a real node, through the app's own client code. Runs
    /// only when both are set (xcodebuild forwards `TEST_RUNNER_`-prefixed env):
    ///   TEST_RUNNER_HLIOS_CAPTURE_LIVE_URL, TEST_RUNNER_HLIOS_CAPTURE_LIVE_PAT
    /// Files one real capture on that node — point it at a throwaway daemon.
    func testLiveMintCaptureAndDedupe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["HLIOS_CAPTURE_LIVE_URL"], let url = URL(string: raw),
              let pat = env["HLIOS_CAPTURE_LIVE_PAT"] else {
            throw XCTSkip("no live node configured")
        }
        let api = HearthAPI(baseURL: url)
        let key = try await api.mintCaptureKey(pat: pat, deviceName: "unit test")

        let thought = CaptureItem(text: "remind me that the iOS capture test ran")
        let first = try await api.postCapture(token: key, item: thought)
        XCTAssertEqual(first.kind, "task")
        XCTAssertFalse(first.duplicate)
        let again = try await api.postCapture(token: key, item: thought)
        XCTAssertTrue(again.duplicate)
        XCTAssertEqual(again.id, first.id)

        // The device token's ingest scope is accepted too.
        let note = try await api.postCapture(token: pat, item: CaptureItem(text: "The capture test also files notes"))
        XCTAssertEqual(note.kind, "note")

        do {
            _ = try await api.postCapture(token: key, item: CaptureItem(text: "   "))
            XCTFail("blank text should be a 400")
        } catch let error as HearthAPI.CaptureError {
            XCTAssertEqual(error, .rejected("nothing to capture"))
        }
        do {
            _ = try await api.postCapture(token: "hl_not_a_key", item: thought)
            XCTFail("a bad key should be rejected")
        } catch let error as HearthAPI.CaptureError {
            XCTAssertEqual(error, .unauthorized)
        }
        // Write-only: the capture key can't read, and can't mint.
        do { try await api.validatePAT(key); XCTFail("capture key must not read") } catch {}
        do { _ = try await api.mintCaptureKey(pat: key, deviceName: "x"); XCTFail("capture key must not mint") } catch {}
    }

    /// The locked-phone path end to end, minus Siri: the intent itself, holding
    /// only the stored capture key (no Connection, no device token). First with
    /// the node unreachable (must queue and still succeed), then reachable
    /// (must drain exactly once). Uses the app's real queue, keychain item and
    /// status, so it only runs on a simulator against a throwaway node.
    func testLiveIntentQueuesOfflineThenDrainsOnce() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["HLIOS_CAPTURE_LIVE_URL"], let url = URL(string: raw),
              let pat = env["HLIOS_CAPTURE_LIVE_PAT"] else {
            throw XCTSkip("no live node configured")
        }
        #if !targetEnvironment(simulator)
        throw XCTSkip("simulator only: this test replaces the app's capture key and queue")
        #endif
        let status = CaptureStatus()
        let cleanUp = {
            CaptureKeyStore.delete()
            CaptureQueue.shared.all().forEach { CaptureQueue.shared.remove(clientRef: $0.clientRef) }
            status.reset()
        }
        cleanUp()
        defer { cleanUp() }

        let key = try await HearthAPI(baseURL: url).mintCaptureKey(pat: pat, deviceName: "intent test")
        let marker = "Intent test \(UUID().uuidString.prefix(8)): the offline queue works"

        // Offline, the slow way: a non-routable address, so the request hangs
        // instead of failing fast. The intent must still answer within budget.
        try CaptureKeyStore.save(CaptureCredential(baseURL: URL(string: "http://10.255.255.1:9")!, key: key))
        var intent = CaptureToHearthloomIntent()
        intent.text = marker
        let started = Date()
        _ = try await intent.perform()
        XCTAssertLessThan(Date().timeIntervalSince(started), CaptureIngestConfig.intentUploadBudget + 3,
                          "the intent answers within its upload budget even when the node hangs")
        XCTAssertEqual(CaptureQueue.shared.all().map(\.text), [marker], "queued, and the intent still succeeded")
        XCTAssertEqual(status.uploadedCount, 0)

        // Network back. The hung upload is still in flight; once it gives up the
        // item is still queued, and the next drain uploads it exactly once.
        try CaptureKeyStore.save(CaptureCredential(baseURL: url, key: key))
        _ = await CaptureService.shared.drain(force: true)   // joins the hung attempt
        XCTAssertEqual(CaptureQueue.shared.count, 1, "a failed upload keeps the item")
        let first = await CaptureService.shared.drain(force: true)
        XCTAssertEqual(first, CaptureDrainResult(uploaded: 1))
        let second = await CaptureService.shared.drain(force: true)
        XCTAssertNil(second)
        XCTAssertTrue(CaptureQueue.shared.all().isEmpty)
        XCTAssertEqual(status.uploadedCount, 1)

        // Online: the intent uploads straight away.
        var online = CaptureToHearthloomIntent()
        online.text = "buy stamps (intent test)"
        _ = try await online.perform()
        XCTAssertTrue(CaptureQueue.shared.all().isEmpty)
        XCTAssertEqual(status.uploadedCount, 2)

        // A revoked/unknown key: kept, and flagged for reconnect.
        try CaptureKeyStore.save(CaptureCredential(baseURL: url, key: "hl_not_a_key"))
        var rejected = CaptureToHearthloomIntent()
        rejected.text = "kept while the key is rejected"
        _ = try await rejected.perform()
        XCTAssertEqual(CaptureQueue.shared.count, 1)
        XCTAssertTrue(status.keyRejected)
    }
}
