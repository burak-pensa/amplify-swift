//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import XCTest

@testable import Amplify
@testable import AWSS3StoragePlugin

// `@unchecked Sendable`: `XCTestCase` is not `Sendable`, but the test body is captured by the
// `@Sendable` closures the API now takes. XCTest runs one test at a time.
class StorageMultipartUploadSessionTests: XCTestCase, @unchecked Sendable {
    enum Failure: Error {
        case unableToCreateData
        case testFailure
    }

    /// Given: A StorageMultipartUploadSession with progressStallTimeoutInterval and a client that stalls (no progress)
    /// When: startUpload is invoked
    /// Then: After the interval, .failed event is received with progress stall timeout error
    func testProgressStallTimeoutWhenNoProgressFailsWithStallError() throws {
        let stallInterval: TimeInterval = 0.05
        let failedExp = expectation(description: "Failed with stall error")

        let client = MockMultipartUploadClient()
        client.shouldStallPartUpload = true

        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated:
                break
            case .inProcess:
                break
            case .failed(let error):
                if case .unknown(let outer, let underlying) = error,
                   outer == "Unable to upload",
                   let stall = underlying as? StorageError,
                   case .unknown(let stallMessage, _) = stall,
                   stallMessage == "Upload cancelled due to progress stall timeout." {
                    failedExp.fulfill()
                }
            case .completed:
                XCTFail("Should not complete when stalling")
            }
        }

        let session = StorageMultipartUploadSession(
            client: client,
            bucket: "bucket",
            key: "key",
            onEvent: onEvent,
            progressStallTimeoutSeconds: stallInterval
        )
        session.startUpload()

        wait(for: [failedExp], timeout: stallInterval + 0.5)
        XCTAssertTrue(session.isAborted)
        XCTAssertEqual(client.abortMultipartUploadCount, 1)
    }

    /// Given: A StorageMultipartUploadSession with a progress stall timeout, whose parts all upload
    ///   successfully and whose CompleteMultipartUpload takes longer than the stall interval
    /// When: the final part completes and completion is in flight
    /// Then: the upload completes and is never aborted — the stall timer must not be armed across
    ///   CompleteMultipartUpload, because no progress event can arrive to reset it
    func testProgressStallTimeoutDoesNotAbortWhileCompletionIsInFlight() throws {
        let stallInterval: TimeInterval = 0.1
        let completedExp = expectation(description: "Completed")

        let client = MockMultipartUploadClient()
        client.completeMultipartUploadDelay = stallInterval * 3

        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated, .inProcess:
                break
            case .failed(let error):
                XCTFail("Must not fail while completion is in flight: \(error)")
            case .completed:
                completedExp.fulfill()
            }
        }

        let session = StorageMultipartUploadSession(
            client: client,
            bucket: "bucket",
            key: "key",
            onEvent: onEvent,
            progressStallTimeoutSeconds: stallInterval
        )
        session.startUpload()

        wait(for: [completedExp], timeout: client.completeMultipartUploadDelay + 1.0)
        XCTAssertTrue(session.isCompleted)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
        XCTAssertEqual(client.completeMultipartUploadCount, 1)
    }

    /// Given: A session whose CompleteMultipartUpload takes longer than the stall interval, paused
    ///   and resumed once every part is done
    /// When: `resume()` re-arms the timer through the `.parts` case, where `uploadParts` finds
    ///   nothing pending, so nothing cancels it again before completion returns
    /// Then: the upload completes and is never aborted -- cancelling at the completion call site is
    ///   not enough on its own, `fireProgressStallTimeout`'s state guard is what closes this one
    func testProgressStallTimeoutDoesNotAbortAfterPauseResumeDuringCompletion() throws {
        let stallInterval: TimeInterval = 0.1
        let completedExp = expectation(description: "Completed")

        let client = MockMultipartUploadClient()
        client.completeMultipartUploadDelay = stallInterval * 3
        client.didCompletePartUpload = { session, _, _, _ in
            guard session.partsCompleted else { return }
            session.pause()
            session.resume()
        }

        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated, .inProcess:
                break
            case .failed(let error):
                XCTFail("Must not fail after pause/resume while completion is in flight: \(error)")
            case .completed:
                completedExp.fulfill()
            }
        }

        let session = StorageMultipartUploadSession(
            client: client,
            bucket: "bucket",
            key: "key",
            onEvent: onEvent,
            progressStallTimeoutSeconds: stallInterval
        )
        session.startUpload()

        wait(for: [completedExp], timeout: client.completeMultipartUploadDelay + 1.0)
        XCTAssertTrue(session.isCompleted)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
        XCTAssertEqual(client.completeMultipartUploadCount, 1)
    }

    /// Given: A session whose parts report an empty eTag, so `validateForCompletion()` fails once
    ///   every part is done, while the stall timer is still armed
    /// When: validation fails and the stall deadline then elapses
    /// Then: the caller is told `.failed` exactly once and no AbortMultipartUpload is sent --
    ///   `fireProgressStallTimeout`'s `case .parts` check is what stops the timer firing in
    ///   `.failed`, which would otherwise abort an upload the caller has already been told failed
    func testProgressStallTimeoutDoesNotAbortAfterCompletionValidationFails() throws {
        let stallInterval: TimeInterval = 0.1
        let failedExp = expectation(description: "Failed exactly once")
        let notAbortedExp = expectation(description: "Never aborted")
        notAbortedExp.isInverted = true
        // Counted rather than fulfilled twice: without the state guard the abort reports a second
        // `.failed` from the stall-timer queue, and an over-fulfilled expectation raises an uncaught
        // `NSInternalInconsistencyException` there, which aborts the process during a later test.
        // Counting keeps the regression a failure of this test and still pins "exactly once".
        let failedCount = AtomicValue(initialValue: 0)

        let client = MockMultipartUploadClient()
        client.eTagForPart = { _ in "" }
        client.didAbortMultipartUpload = { _, _ in notAbortedExp.fulfill() }

        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated, .inProcess:
                break
            case .failed:
                if failedCount.increment() == 1 {
                    failedExp.fulfill()
                }
            case .completed:
                XCTFail("Must not complete when the parts fail validation")
            }
        }

        let session = StorageMultipartUploadSession(
            client: client,
            bucket: "bucket",
            key: "key",
            onEvent: onEvent,
            progressStallTimeoutSeconds: stallInterval
        )
        session.startUpload()

        wait(for: [failedExp], timeout: stallInterval + 0.5)
        wait(for: [notAbortedExp], timeout: stallInterval * 4)
        XCTAssertEqual(failedCount.get(), 1)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
        XCTAssertEqual(client.completeMultipartUploadCount, 0)
    }

    func testSessionCreation() throws {
        let bucket = "my-bucket"
        let key = "key.txt"
        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated:
                print("Initiated")
            case .inProcess(let progress):
                print("Progress: \(String(format: "%.2f", progress.fractionCompleted))")
            case .failed:
                print("Failed")
                XCTFail("Must not fail")
            case .completed:
                print("Completed")
            }
        }

        let client = MockMultipartUploadClient()
        let session = StorageMultipartUploadSession(client: client, bucket: bucket, key: key, onEvent: onEvent)
        XCTAssertEqual(session.partsCount, 0)
        XCTAssertEqual(session.inProgressCount, 0)
        XCTAssertFalse(session.partsCompleted)
        XCTAssertFalse(session.partsFailed)
    }

    /// Given: A StorageTransferTask with a valid StorageTransferType
    /// When: A StorageMultipartUploadSession is created from the task
    /// Then: Its values are set correctly
    func testSessionCreation_withTransferTask() throws {
        let client = MockMultipartUploadClient()
        let transferType: StorageTransferType = .multiPartUpload(onEvent: {_ in })
        let transferTask = StorageTransferTask(
            transferType: transferType,
            bucket: "bucket",
            key: "key"
        )

        let session = try XCTUnwrap(StorageMultipartUploadSession(client: client, transferTask: transferTask, multipartUpload: .none, logger: MockLogger()))
        XCTAssertEqual(session.partsCount, 0)
        XCTAssertEqual(session.inProgressCount, 0)
        XCTAssertFalse(session.partsCompleted)
        XCTAssertFalse(session.partsFailed)
    }

    /// Given: A StorageTransferTask with an invalid StorageTransferType
    /// When: A StorageMultipartUploadSession is created from the task
    /// Then: Its values are set correctly
    func testSessionCreation_withTransferTask_andInvalidTransferType_shouldReturnNil() throws {
        let client = MockMultipartUploadClient()
        let transferType: StorageTransferType = .list(onEvent: {_ in })
        let transferTask = StorageTransferTask(
            transferType: transferType,
            bucket: "bucket",
            key: "key"
        )

        XCTAssertNil(StorageMultipartUploadSession(
            client: client,
            transferTask: transferTask,
            multipartUpload: .none
        ))
    }

    func testCompletedMultipartUploadSession() throws {
        let initiatedExp = expectation(description: "Initiated")
        let completedExp = expectation(description: "Completed")

        let bucket = "my-bucket"
        let key = "key.txt"
        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated:
                print("Initiated")
                initiatedExp.fulfill()
            case .inProcess(let progress):
                print("Progress: \(String(format: "%.2f", progress.fractionCompleted))")
            case .failed(let error):
                print("Error: \(error)")
                XCTFail("Must not fail")
            case .completed:
                print("Completed")
                completedExp.fulfill()
            }
        }

        let client = MockMultipartUploadClient() // creates an UploadFile for the mock process
        let session = StorageMultipartUploadSession(client: client, bucket: bucket, key: key, onEvent: onEvent)

        session.startUpload()

        wait(for: [initiatedExp, completedExp], timeout: 300.0)

        XCTAssertEqual(session.inProgressCount, 0)
        XCTAssertTrue(session.isCompleted)

        XCTAssertEqual(client.completeMultipartUploadCount, 1)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
        XCTAssertEqual(client.errorCount, 0)
        XCTAssertGreaterThan(client.uploadPartCount, 0)
    }

    func testAbortedMultipartUploadSession() throws {
        let initiatedExp = expectation(description: "Initiated")
        let completedExp = expectation(description: "Completed")

        var closureSession: StorageMultipartUploadSession?
        let bucket = "my-bucket"
        let key = "key.txt"
        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated:
                print("Initiated")
                initiatedExp.fulfill()
            case .inProcess(let progress):
                print("Progress: \(String(format: "%.2f", progress.fractionCompleted))")
            case .failed(let error):
                print("Error: \(error)")
                completedExp.fulfill()
            case .completed:
                print("Completed")
                XCTFail("Must not complete")
                completedExp.fulfill()
            }
        }

        let client = MockMultipartUploadClient() // creates an UploadFile for the mock process
        client.didCompletePartUpload = { _, partNumber, _, _ in
            if partNumber == 5 {
                closureSession?.cancel()
                XCTAssertTrue(closureSession?.isAborted ?? false)
            }

        }
        let session = StorageMultipartUploadSession(client: client, bucket: bucket, key: key, onEvent: onEvent)
        closureSession = session

        session.startUpload()

        wait(for: [initiatedExp, completedExp], timeout: 300.0)

        XCTAssertEqual(session.inProgressCount, 0)
        XCTAssertTrue(session.isAborted)

        XCTAssertEqual(client.completeMultipartUploadCount, 0)
        XCTAssertEqual(client.abortMultipartUploadCount, 1)
        XCTAssertEqual(client.errorCount, 0)
        XCTAssertGreaterThan(client.uploadPartCount, 0)
        closureSession = nil
    }

    func testPauseAndResumeMultipartUploadSession() throws {
        let initiatedExp = expectation(description: "Initiated")
        let completedExp = expectation(description: "Completed")

        var closureSession: StorageMultipartUploadSession?
        var pauseCount = 0
        let bucket = "my-bucket"
        let key = "key.txt"
        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated:
                print("Initiated")
                initiatedExp.fulfill()
            case .inProcess(let progress):
                print("Progress: \(String(format: "%.2f", progress.fractionCompleted))")
            case .failed(let error):
                print("Error: \(error)")
                XCTFail("Must not fail")
            case .completed:
                print("Completed")
                completedExp.fulfill()
            }
        }

        let client = MockMultipartUploadClient() // creates an UploadFile for the mock process
        client.didTransferBytesForPartUpload = { _, partNumber, bytesTransferred in
            if pauseCount == 0, partNumber > 5, bytesTransferred > 0 {
                print("pausing on \(partNumber)")
                pauseCount += 1
                closureSession?.pause()
                XCTAssertTrue(closureSession?.isPaused ?? false)
                print("resuming on \(partNumber)")
                closureSession?.resume()
                XCTAssertFalse(closureSession?.isPaused ?? true)
            }
        }

        let session = StorageMultipartUploadSession(client: client, bucket: bucket, key: key, onEvent: onEvent)
        closureSession = session

        session.startUpload()

        wait(for: [initiatedExp, completedExp], timeout: 300.0)

        XCTAssertEqual(session.inProgressCount, 0)
        XCTAssertTrue(session.isCompleted)

        XCTAssertEqual(client.completeMultipartUploadCount, 1)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
        XCTAssertEqual(client.errorCount, 0)
        XCTAssertGreaterThan(client.uploadPartCount, 0)
        closureSession = nil
    }

    func testPartUploadFailedOnce() throws {
        let initiatedExp = expectation(description: "Initiated")
        let completedExp = expectation(description: "Completed")

        var failCount = 0
        let bucket = "my-bucket"
        let key = "key.txt"
        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated:
                print("Initiated")
                initiatedExp.fulfill()
            case .inProcess(let progress):
                print("Progress: \(String(format: "%.2f", progress.fractionCompleted))")
            case .failed(let error):
                print("Error: \(error)")
                XCTFail("Must not fail")
            case .completed:
                print("Completed")
                completedExp.fulfill()
            }
        }

        let client = MockMultipartUploadClient() // creates an UploadFile for the mock process
        client.shouldFailPartUpload = { _, partNumber in
            if failCount == 0, partNumber == 5 {
                print("failing on \(partNumber)")
                failCount += 1
                return true
            } else {
                return false
            }
        }

        let session = StorageMultipartUploadSession(client: client, bucket: bucket, key: key, onEvent: onEvent)

        session.startUpload()

        wait(for: [initiatedExp, completedExp], timeout: 300.0)

        XCTAssertEqual(session.inProgressCount, 0)
        XCTAssertTrue(session.isCompleted)

        XCTAssertEqual(client.completeMultipartUploadCount, 1)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
        XCTAssertEqual(client.errorCount, 0)
        XCTAssertGreaterThan(client.uploadPartCount, 0)
    }

    func testPartUploadFailedOverLimit() throws {
        try XCTSkipIf(true, "Temporarily disabling test which only fails on GitHub CI/CD")
        let initiatedExp = expectation(description: "Initiated")
        let completedExp = expectation(description: "Completed")

        var failCount = 0
        let bucket = "my-bucket"
        let key = "key.txt"
        let onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler = { event in
            switch event {
            case .initiated:
                print("Initiated")
                initiatedExp.fulfill()
            case .inProcess(let progress):
                print("Progress: \(String(format: "%.2f", progress.fractionCompleted))")
            case .failed(let error):
                print("Error: \(error)")
                XCTFail("Must not fail")
            case .completed:
                print("Completed")
                completedExp.fulfill()
            }
        }

        let client = MockMultipartUploadClient() // creates an UploadFile for the mock process
        client.shouldFailPartUpload = { _, partNumber in
            if partNumber == 5 {
                print("failing on \(partNumber)")
                failCount += 1
                return true
            } else {
                return false
            }
        }

        let session = StorageMultipartUploadSession(client: client, bucket: bucket, key: key, onEvent: onEvent)

        session.startUpload()

        wait(for: [initiatedExp, completedExp], timeout: 300.0)

        XCTAssertEqual(session.inProgressCount, 0)
        XCTAssertTrue(session.isAborted)

        XCTAssertEqual(client.completeMultipartUploadCount, 0)
        XCTAssertEqual(client.abortMultipartUploadCount, 1)
        XCTAssertEqual(client.errorCount, 0)
        XCTAssertGreaterThan(client.uploadPartCount, 0)
    }

    // MARK: - Private -

    private func createFile() throws -> URL {
        let size = Int(minimumPartSize)
        let parts: [String] = [
            Array(repeating: "a", count: size).joined(),
            Array(repeating: "b", count: size).joined(),
            Array(repeating: "c", count: size).joined(),
            Array(repeating: "d", count: size).joined(),
            Array(repeating: "e", count: size).joined(),
            Array(repeating: "f", count: size / 2).joined()
        ]
        let string = parts.joined()

        let data = Data(string.utf8)
        let fileURL = try FileSystem.default.createTemporaryFile(data: data)
        return fileURL
    }

}

// MARK: - Progress stall timer: bytes sent and late fires (APP-965 option C)

/// A clock for the stall timer that can jump forward, to make a fire look late without waiting.
private final class StallTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offsetNanoseconds: UInt64 = 0
    private var jumped = false

    func now() -> DispatchTime {
        lock.lock()
        defer { lock.unlock() }
        return DispatchTime(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + offsetNanoseconds)
    }

    /// Moves the clock forward once; later calls do nothing.
    func jumpOnce(seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !jumped else { return }
        jumped = true
        offsetNanoseconds += UInt64(seconds * 1_000_000_000)
    }
}

/// Records what the upload reported, with times, without fulfilling an expectation twice.
private final class StallEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stallFailureCount = 0
    private(set) var otherFailureCount = 0
    private(set) var completedCount = 0
    private(set) var firstStallFailureAt: DispatchTime?
    let stallFailed: XCTestExpectation
    let completed: XCTestExpectation

    init(stallFailed: XCTestExpectation, completed: XCTestExpectation) {
        self.stallFailed = stallFailed
        self.completed = completed
    }

    var onEvent: AWSS3StorageServiceBehavior.StorageServiceMultiPartUploadEventHandler {
        { [self] event in
            switch event {
            case .initiated, .inProcess:
                break
            case .failed(let error):
                lock.lock()
                let isStall: Bool
                if case .unknown(_, let underlying) = error,
                   let stall = underlying as? StorageError,
                   case .unknown(let message, _) = stall,
                   message == "Upload cancelled due to progress stall timeout." {
                    isStall = true
                } else {
                    isStall = false
                }
                if isStall {
                    stallFailureCount += 1
                    if firstStallFailureAt == nil { firstStallFailureAt = .now() }
                } else {
                    otherFailureCount += 1
                }
                let fulfill = isStall && stallFailureCount == 1
                lock.unlock()
                if fulfill { stallFailed.fulfill() }
            case .completed:
                lock.lock()
                completedCount += 1
                let fulfill = completedCount == 1
                lock.unlock()
                if fulfill { completed.fulfill() }
            }
        }
    }
}

private func seconds(from start: DispatchTime, to end: DispatchTime?) -> TimeInterval {
    guard let end else { return -1 }
    return TimeInterval(Int64(bitPattern: end.uptimeNanoseconds &- start.uptimeNanoseconds)) / 1_000_000_000
}

extension StorageMultipartUploadSessionTests {

    private func makeRecorder(expectStall: Bool, expectCompletion: Bool) -> StallEventRecorder {
        let stallFailed = expectation(description: "Failed with stall error")
        stallFailed.isInverted = !expectStall
        let completed = expectation(description: "Completed")
        completed.isInverted = !expectCompletion
        return StallEventRecorder(stallFailed: stallFailed, completed: completed)
    }

    private func makeStallSession(
        client: MockMultipartUploadClient,
        recorder: StallEventRecorder,
        stallInterval: TimeInterval,
        confirmWindow: TimeInterval,
        clock: StallTestClock = StallTestClock()
    ) -> StorageMultipartUploadSession {
        StorageMultipartUploadSession(
            client: client,
            bucket: "bucket",
            key: "key",
            onEvent: recorder.onEvent,
            progressStallTimeoutSeconds: stallInterval,
            stallTimerClock: { clock.now() },
            stallConfirmWindowSeconds: confirmWindow
        )
    }

    /// T2.
    /// Given: parts that send no events, while their URLSession tasks keep sending bytes for three
    ///   stall intervals and then stop
    /// When: the stall timer fires on time each interval
    /// Then: each fire that finds new bytes re-arms instead of aborting, and the first fire that
    ///   finds no new bytes aborts, exactly once
    func testStallTimerReArmsWhileTasksSendBytesWithoutEvents() {
        let stallInterval: TimeInterval = 0.1
        let client = MockMultipartUploadClient()
        client.shouldStallPartUpload = true
        client.bytesSentForTask = { [unowned client] _ in
            Int64(min(client.bytesSentCallCount, 3)) * 1_000
        }
        let recorder = makeRecorder(expectStall: true, expectCompletion: false)
        let session = makeStallSession(client: client, recorder: recorder, stallInterval: stallInterval, confirmWindow: 5)

        let start = DispatchTime.now()
        session.startUpload()

        wait(for: [recorder.stallFailed, recorder.completed], timeout: stallInterval * 4 + 1.0)
        XCTAssertGreaterThanOrEqual(seconds(from: start, to: recorder.firstStallFailureAt), stallInterval * 4 * 0.9)
        XCTAssertEqual(client.bytesSentCallCount, 4)
        XCTAssertEqual(recorder.stallFailureCount, 1)
        XCTAssertEqual(client.abortMultipartUploadCount, 1)
    }

    /// T3.
    /// Given: parts that sent bytes with progress events and then stopped, so each task's
    ///   countOfBytesSent equals the last totalBytesSent the session saw
    /// When: the stall timer fires on time
    /// Then: bytes the session already saw do not count as movement, and the upload aborts at the
    ///   stall interval, not after the confirm window
    func testStallTimerAbortsOnTimeWhenBytesWereAlreadySeen() {
        let stallInterval: TimeInterval = 0.1
        let client = MockMultipartUploadClient()
        client.shouldStallPartUploadAfterProgress = true
        client.bytesSentForTask = { [unowned client] taskIdentifier in
            client.reportedTotalBytesSent(taskIdentifier: taskIdentifier).map { Int64($0) }
        }
        let recorder = makeRecorder(expectStall: true, expectCompletion: false)
        let session = makeStallSession(client: client, recorder: recorder, stallInterval: stallInterval, confirmWindow: 5)

        session.startUpload()

        wait(for: [recorder.stallFailed, recorder.completed], timeout: stallInterval + 1.0)
        XCTAssertEqual(recorder.stallFailureCount, 1)
        XCTAssertEqual(client.abortMultipartUploadCount, 1)
    }

    /// T4 (APP-965 §1.4(2), deferred start).
    /// Given: parts that send no events and no bytes
    /// When: the stall timer fires long after its deadline, as after an app resume
    /// Then: it waits one confirm window, finds nothing again, and aborts exactly once
    func testLateStallFireWithoutMovementAbortsOnceAfterConfirmWindow() {
        let stallInterval: TimeInterval = 0.1
        let confirmWindow: TimeInterval = 0.3
        let clock = StallTestClock()
        let firstFireAt = AtomicValue<DispatchTime?>(initialValue: nil)
        let client = MockMultipartUploadClient()
        client.shouldStallPartUpload = true
        client.bytesSentForTask = { _ in
            if firstFireAt.get() == nil { firstFireAt.set(.now()) }
            clock.jumpOnce(seconds: 300)
            return 0
        }
        let recorder = makeRecorder(expectStall: true, expectCompletion: false)
        let session = makeStallSession(
            client: client,
            recorder: recorder,
            stallInterval: stallInterval,
            confirmWindow: confirmWindow,
            clock: clock
        )

        session.startUpload()

        wait(for: [recorder.stallFailed, recorder.completed], timeout: stallInterval + confirmWindow + 1.0)
        guard let firstFire = firstFireAt.get() else {
            XCTFail("The stall timer never read the tasks' bytes sent")
            return
        }
        XCTAssertGreaterThanOrEqual(seconds(from: firstFire, to: recorder.firstStallFailureAt), confirmWindow * 0.9)
        XCTAssertEqual(client.bytesSentCallCount, 2)
        XCTAssertEqual(recorder.stallFailureCount, 1)
        XCTAssertEqual(client.abortMultipartUploadCount, 1)
    }

    /// T5 (APP-965 §1.4(3), wake race).
    /// Given: parts that send no events while the app is suspended
    /// When: the stall timer fires late, and every in-flight part's `.completed` arrives inside the
    ///   confirm window
    /// Then: the upload is not aborted and completes
    func testLateStallFireDoesNotAbortWhenPartsCompleteInConfirmWindow() {
        let stallInterval: TimeInterval = 0.1
        let confirmWindow: TimeInterval = 0.3
        let clock = StallTestClock()
        let client = MockMultipartUploadClient()
        client.shouldStallPartUpload = true
        let scheduled = AtomicValue(initialValue: false)
        client.bytesSentForTask = { [unowned client] _ in
            clock.jumpOnce(seconds: 300)
            if !scheduled.getAndSet(true) {
                DispatchQueue.global().asyncAfter(deadline: .now() + confirmWindow / 3) {
                    client.shouldStallPartUpload = false
                    client.completeStalledParts()
                }
            }
            return 0
        }
        let recorder = makeRecorder(expectStall: false, expectCompletion: true)
        let session = makeStallSession(
            client: client,
            recorder: recorder,
            stallInterval: stallInterval,
            confirmWindow: confirmWindow,
            clock: clock
        )

        session.startUpload()

        wait(for: [recorder.completed, recorder.stallFailed], timeout: stallInterval + confirmWindow * 2)
        XCTAssertTrue(session.isCompleted)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
        XCTAssertEqual(client.completeMultipartUploadCount, 1)
    }

    /// T6.
    /// Given: parts that send no events, and a progress event for every in-flight part that is
    ///   handled while the stall timer is already deciding (here: during its bytes-sent read)
    /// When: that fire reaches its abort step
    /// Then: it does not abort, because an event arrived after it was armed; the reset that event
    ///   queued re-arms the timer, and the upload aborts exactly once, one interval later
    func testStallFireDoesNotAbortWhenEventArrivesDuringFire() {
        let stallInterval: TimeInterval = 0.1
        let client = MockMultipartUploadClient()
        client.shouldStallPartUpload = true
        let delivered = AtomicValue(initialValue: false)
        client.bytesSentForTask = { [unowned client] _ in
            if !delivered.getAndSet(true) {
                client.reportProgressForStalledParts(totalBytesSent: 1_000)
            }
            return nil
        }
        let recorder = makeRecorder(expectStall: true, expectCompletion: false)
        let session = makeStallSession(client: client, recorder: recorder, stallInterval: stallInterval, confirmWindow: 5)

        let start = DispatchTime.now()
        session.startUpload()

        wait(for: [recorder.stallFailed, recorder.completed], timeout: stallInterval * 2 + 1.0)
        XCTAssertGreaterThanOrEqual(seconds(from: start, to: recorder.firstStallFailureAt), stallInterval * 2 * 0.9)
        XCTAssertEqual(client.bytesSentCallCount, 2)
        XCTAssertEqual(recorder.stallFailureCount, 1)
        XCTAssertEqual(client.abortMultipartUploadCount, 1)
    }

    /// T7.
    /// Given: a late fire where one in-flight part's task is no longer registered (it finished and
    ///   was unregistered) and the others report no bytes
    /// When: the parts' `.completed` events arrive inside the confirm window
    /// Then: the upload is not aborted and completes
    func testLateStallFireDoesNotAbortWhenUnregisteredPartCompletesInConfirmWindow() {
        let stallInterval: TimeInterval = 0.1
        let confirmWindow: TimeInterval = 0.3
        let clock = StallTestClock()
        let client = MockMultipartUploadClient()
        client.shouldStallPartUpload = true
        let scheduled = AtomicValue(initialValue: false)
        client.bytesSentForTask = { [unowned client] taskIdentifier in
            clock.jumpOnce(seconds: 300)
            if !scheduled.getAndSet(true) {
                DispatchQueue.global().asyncAfter(deadline: .now() + confirmWindow / 3) {
                    client.shouldStallPartUpload = false
                    client.completeStalledParts()
                }
            }
            return taskIdentifier == client.stalledTaskIdentifiers.first ? nil : 0
        }
        let recorder = makeRecorder(expectStall: false, expectCompletion: true)
        let session = makeStallSession(
            client: client,
            recorder: recorder,
            stallInterval: stallInterval,
            confirmWindow: confirmWindow,
            clock: clock
        )

        session.startUpload()

        wait(for: [recorder.completed, recorder.stallFailed], timeout: stallInterval + confirmWindow * 2)
        XCTAssertTrue(session.isCompleted)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
    }

    /// T8.
    /// Given: parts that reported progress, whose tasks now report fewer bytes than the session saw
    ///   (as a retried part on a new task would)
    /// When: the stall timer fires on time
    /// Then: that is no movement: no re-arm loop, one abort at the stall interval
    func testStallTimerTreatsBytesBelowBaselineAsNoMovement() {
        let stallInterval: TimeInterval = 0.1
        let client = MockMultipartUploadClient()
        client.shouldStallPartUploadAfterProgress = true
        client.bytesSentForTask = { _ in 1 }
        let recorder = makeRecorder(expectStall: true, expectCompletion: false)
        let session = makeStallSession(client: client, recorder: recorder, stallInterval: stallInterval, confirmWindow: 5)

        session.startUpload()

        wait(for: [recorder.stallFailed, recorder.completed], timeout: stallInterval + 1.0)
        XCTAssertEqual(recorder.stallFailureCount, 1)
        XCTAssertEqual(client.abortMultipartUploadCount, 1)
    }

    /// T9.
    /// Given: a late fire that opened a confirm window
    /// When: the upload is paused inside the window, and later resumed with parts that complete
    /// Then: the paused upload is never aborted, and after resume it completes
    func testPauseDuringConfirmWindowDoesNotAbort() {
        let stallInterval: TimeInterval = 0.1
        let confirmWindow: TimeInterval = 0.3
        let clock = StallTestClock()
        let client = MockMultipartUploadClient()
        client.shouldStallPartUpload = true
        let paused = expectation(description: "Paused")
        let scheduled = AtomicValue(initialValue: false)
        client.bytesSentForTask = { [unowned client] _ in
            clock.jumpOnce(seconds: 300)
            if !scheduled.getAndSet(true) {
                DispatchQueue.global().asyncAfter(deadline: .now() + confirmWindow / 3) {
                    client.session?.pause()
                    paused.fulfill()
                }
            }
            return 0
        }
        let recorder = makeRecorder(expectStall: false, expectCompletion: true)
        let session = makeStallSession(
            client: client,
            recorder: recorder,
            stallInterval: stallInterval,
            confirmWindow: confirmWindow,
            clock: clock
        )

        session.startUpload()
        wait(for: [paused], timeout: stallInterval + 1.0)
        // Hold the pause well past the confirm window: nothing may fire.
        Thread.sleep(forTimeInterval: confirmWindow * 2)
        XCTAssertTrue(session.isPaused)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)

        client.shouldStallPartUpload = false
        session.resume()

        wait(for: [recorder.completed, recorder.stallFailed], timeout: 1.0)
        XCTAssertTrue(session.isCompleted)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
    }

    /// T10.
    /// Given: a late fire that opened a confirm window, and a CompleteMultipartUpload that takes
    ///   longer than the window
    /// When: every part completes inside the window, so completion is in flight when it ends
    /// Then: the upload completes and is never aborted
    func testConfirmWindowDoesNotAbortWhileCompletionIsInFlight() {
        let stallInterval: TimeInterval = 0.1
        let confirmWindow: TimeInterval = 0.3
        let clock = StallTestClock()
        let client = MockMultipartUploadClient()
        client.shouldStallPartUpload = true
        client.completeMultipartUploadDelay = confirmWindow * 3
        let scheduled = AtomicValue(initialValue: false)
        client.bytesSentForTask = { [unowned client] _ in
            clock.jumpOnce(seconds: 300)
            if !scheduled.getAndSet(true) {
                DispatchQueue.global().asyncAfter(deadline: .now() + confirmWindow / 3) {
                    client.shouldStallPartUpload = false
                    client.completeStalledParts()
                }
            }
            return 0
        }
        let recorder = makeRecorder(expectStall: false, expectCompletion: true)
        let session = makeStallSession(
            client: client,
            recorder: recorder,
            stallInterval: stallInterval,
            confirmWindow: confirmWindow,
            clock: clock
        )

        session.startUpload()

        wait(for: [recorder.completed, recorder.stallFailed], timeout: stallInterval + client.completeMultipartUploadDelay + 1.0)
        XCTAssertTrue(session.isCompleted)
        XCTAssertEqual(client.abortMultipartUploadCount, 0)
        XCTAssertEqual(client.completeMultipartUploadCount, 1)
    }
}
