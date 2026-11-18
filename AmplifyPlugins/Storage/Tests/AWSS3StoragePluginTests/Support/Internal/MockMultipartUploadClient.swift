//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import XCTest

@testable import Amplify
@testable import AWSS3StoragePlugin

// `@unchecked Sendable`: `completeMultipartUploadDelay` reports completion from a global queue; the counters are lock-guarded.
class MockMultipartUploadClient: StorageMultipartUploadClient, @unchecked Sendable {

    enum Failure: Error {
        case sessionNotIntegrated
        case mockFailure
    }

    private let counterLock = NSLock()
    var uploadPartCount = 0
    var completeMultipartUploadCount = 0
    var abortMultipartUploadCount = 0
    var errorCount = 0
    var taskIdentifier = 100

    private func increment(_ keyPath: ReferenceWritableKeyPath<MockMultipartUploadClient, Int>) {
        counterLock.lock()
        defer { counterLock.unlock() }
        self[keyPath: keyPath] += 1
    }

    let uploadFile: UploadFile
    var session: StorageMultipartUploadSession?

    var didCreate: ((StorageMultipartUploadSession) -> Void)?
    var didStartPartUpload: ((StorageMultipartUploadSession, PartNumber) -> Void)?
    var didTransferBytesForPartUpload: ((StorageMultipartUploadSession, PartNumber, UInt64) -> Void)?
    var shouldFailPartUpload: ((StorageMultipartUploadSession, PartNumber) -> Bool)?
    /// When true, uploadPart only reports started but never progress/completed (for stall timeout testing)
    var shouldStallPartUpload = false
    /// When true, uploadPart reports started and one progress event, then nothing (for stall timeout testing)
    var shouldStallPartUploadAfterProgress = false
    /// Answers `bytesSent(taskIdentifiers:)` per task. nil leaves the task out, as an unregistered task.
    var bytesSentForTask: ((TaskIdentifier) -> Int64?)?
    private(set) var bytesSentCallCount = 0
    /// Parts that started and have not been reported completed by this mock, with their task identifiers.
    private var stalledParts: [PartNumber: TaskIdentifier] = [:]
    /// The last `totalBytesSent` this mock reported per task.
    private var reportedTotalBytesSent: [TaskIdentifier: UInt64] = [:]
    /// Every task identifier this mock started and left stalled. A cancel does not remove one.
    private var everStalledTasks: [TaskIdentifier] = []
    /// One entry per `cancelUploadTasks` call, in call order.
    private var cancelUploadTasksCalls: [[TaskIdentifier]] = []
    /// What had been cancelled when `abortMultipartUpload` was first called.
    private var cancelledTasksAtFirstAbort: [TaskIdentifier]?
    /// Delays the `.completed` event from `completeMultipartUpload`, simulating a slow request.
    var completeMultipartUploadDelay: TimeInterval = 0
    /// Overrides the eTag a completed part reports. An empty eTag fails `validateForCompletion()`.
    var eTagForPart: ((PartNumber) -> String)?
    var didCompletePartUpload: ((StorageMultipartUploadSession, PartNumber, String, TaskIdentifier) -> Void)?
    var didFailPartUpload: ((StorageMultipartUploadSession, PartNumber, Error) -> Void)?
    var didCompleteMultipartUpload: ((StorageMultipartUploadSession, UploadID) -> Void)?
    var didAbortMultipartUpload: ((StorageMultipartUploadSession, UploadID) -> Void)?

    init(uploadFile: UploadFile? = nil) {
        self.uploadFile = uploadFile ?? UploadFile(fileURL: URL(fileURLWithPath: "/tmp/upload.txt"), temporaryFileCreated: true, size: UInt64(Bytes.megabytes(42).bytes))
    }

    func integrate(session: StorageMultipartUploadSession) {
        self.session = session
    }

    func createMultipartUpload() throws {
        guard let session else { throw Failure.sessionNotIntegrated }

        let uploadId = UUID().uuidString
        session.handle(multipartUploadEvent: .created(uploadFile: uploadFile, uploadId: uploadId))
        didCreate?(session)
    }

    func uploadPart(partNumber: PartNumber, multipartUpload: StorageMultipartUpload, subTask: StorageTransferTask) throws {
        guard let _ = multipartUpload.uploadFile,
              let _ = multipartUpload.uploadId,
              let _ = multipartUpload.partSize,
              let part = multipartUpload.part(for: partNumber) else {
                  fatalError()
              }
        print("Upload Part \(partNumber)")
        guard let session else { throw Failure.sessionNotIntegrated }

        increment(\.uploadPartCount)

        defer {
            increment(\.taskIdentifier)
        }

        subTask.sessionTask = MockStorageSessionTask(taskIdentifier: taskIdentifier, state: .suspended)
        session.handle(uploadPartEvent: .started(partNumber: partNumber, taskIdentifier: taskIdentifier))
        didStartPartUpload?(session, partNumber)

        guard !shouldStallPartUpload else {
            withLock {
                stalledParts[partNumber] = taskIdentifier
                everStalledTasks.append(taskIdentifier)
            }
            return
        }

        let bytesTransferred = part.bytes / 2
        withLock { reportedTotalBytesSent[taskIdentifier] = bytesTransferred }
        session.handle(uploadPartEvent: .progressUpdated(
            partNumber: partNumber,
            bytesTransferred: bytesTransferred,
            taskIdentifier: taskIdentifier,
            totalBytesSent: bytesTransferred
        ))
        didTransferBytesForPartUpload?(session, partNumber, bytesTransferred)

        guard !shouldStallPartUploadAfterProgress else {
            withLock {
                stalledParts[partNumber] = taskIdentifier
                everStalledTasks.append(taskIdentifier)
            }
            return
        }

        if shouldFailPartUpload?(session, partNumber) ?? false {
            session.handle(uploadPartEvent: .failed(partNumber: partNumber, error: Failure.mockFailure))
            return
        }

        if let part = session.part(for: partNumber) {
            if part.inProgress {
                let eTag = eTagForPart?(partNumber) ?? UUID().uuidString
                session.handle(uploadPartEvent: .completed(partNumber: partNumber, eTag: eTag, taskIdentifier: taskIdentifier))
                didCompletePartUpload?(session, partNumber, eTag, taskIdentifier)
            }
        }
    }

    func completeMultipartUpload(uploadId: UploadID) throws {
        guard let session else { throw Failure.sessionNotIntegrated }

        increment(\.completeMultipartUploadCount)

        guard completeMultipartUploadDelay > 0 else {
            session.handle(multipartUploadEvent: .completed(uploadId: uploadId))
            didCompleteMultipartUpload?(session, uploadId)
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + completeMultipartUploadDelay) {
            session.handle(multipartUploadEvent: .completed(uploadId: uploadId))
            self.didCompleteMultipartUpload?(session, uploadId)
        }
    }

    func abortMultipartUpload(uploadId: UploadID, error: Error?) throws {
        guard let session else { throw Failure.sessionNotIntegrated }

        increment(\.abortMultipartUploadCount)
        withLock {
            if cancelledTasksAtFirstAbort == nil {
                cancelledTasksAtFirstAbort = cancelUploadTasksCalls.flatMap { $0 }
            }
        }

        session.handle(multipartUploadEvent: .aborted(uploadId: uploadId, error: error))
        didAbortMultipartUpload?(session, uploadId)
    }

    func cancelUploadTasks(taskIdentifiers: [TaskIdentifier], done: @escaping () -> Void) {
        print("Canceling upload tasks")
        withLock {
            cancelUploadTasksCalls.append(taskIdentifiers)
            stalledParts = stalledParts.filter { !taskIdentifiers.contains($0.value) }
        }
        done()
    }

    /// Every task identifier this mock started and left stalled, cancelled or not.
    var everStalledTaskIdentifiers: [TaskIdentifier] {
        withLock { everStalledTasks }
    }

    /// The task identifiers of each `cancelUploadTasks` call, in call order.
    var cancelUploadTasksCallArguments: [[TaskIdentifier]] {
        withLock { cancelUploadTasksCalls }
    }

    /// The task identifiers that had been cancelled when `abortMultipartUpload` was first called,
    /// or nil if it was never called.
    var cancelledTaskIdentifiersAtFirstAbort: [TaskIdentifier]? {
        withLock { cancelledTasksAtFirstAbort }
    }

    func bytesSent(taskIdentifiers: [TaskIdentifier]) -> [TaskIdentifier: Int64] {
        increment(\.bytesSentCallCount)
        var result: [TaskIdentifier: Int64] = [:]
        for taskIdentifier in taskIdentifiers {
            result[taskIdentifier] = bytesSentForTask?(taskIdentifier)
        }
        return result
    }

    /// The `totalBytesSent` this mock last reported for a task, or nil.
    func reportedTotalBytesSent(taskIdentifier: TaskIdentifier) -> UInt64? {
        withLock { reportedTotalBytesSent[taskIdentifier] }
    }

    /// Task identifiers of the parts that started and stalled, in part order.
    var stalledTaskIdentifiers: [TaskIdentifier] {
        withLock { stalledParts.sorted { $0.key < $1.key }.map(\.value) }
    }

    /// Reports `.completed` for every part that stalled. Parts this starts afterwards follow the
    /// stall flags, so clear them first to let the rest of the upload finish.
    func completeStalledParts() {
        guard let session else { return }
        let parts = withLock {
            let parts = stalledParts.sorted { $0.key < $1.key }
            stalledParts = [:]
            return parts
        }
        for (partNumber, taskIdentifier) in parts {
            let eTag = eTagForPart?(partNumber) ?? UUID().uuidString
            session.handle(uploadPartEvent: .completed(partNumber: partNumber, eTag: eTag, taskIdentifier: taskIdentifier))
        }
    }

    /// Reports one `.progressUpdated` for every part that stalled, with `totalBytesSent` as the running total.
    func reportProgressForStalledParts(totalBytesSent: UInt64) {
        guard let session else { return }
        let parts = withLock { stalledParts.sorted { $0.key < $1.key } }
        for (partNumber, taskIdentifier) in parts {
            withLock { reportedTotalBytesSent[taskIdentifier] = totalBytesSent }
            session.handle(uploadPartEvent: .progressUpdated(
                partNumber: partNumber,
                bytesTransferred: totalBytesSent,
                taskIdentifier: taskIdentifier,
                totalBytesSent: totalBytesSent
            ))
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        counterLock.lock()
        defer { counterLock.unlock() }
        return body()
    }

}
