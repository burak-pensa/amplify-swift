//
// Copyright Amazon.com Inc. or its affiliates.
// All Rights Reserved.
//
// SPDX-License-Identifier: Apache-2.0
//

import Foundation

enum StorageUploadPartEvent {
    case queued(partNumber: PartNumber)
    case started(partNumber: PartNumber, taskIdentifier: TaskIdentifier)
    /// `bytesTransferred` is the delta of the last `didSendBodyData` callback, as before.
    /// `totalBytesSent` is the task's running total, which the stall timer uses as its baseline.
    case progressUpdated(partNumber: PartNumber, bytesTransferred: UInt64, taskIdentifier: TaskIdentifier, totalBytesSent: UInt64)
    case completed(partNumber: PartNumber, eTag: String, taskIdentifier: TaskIdentifier)
    case failed(partNumber: PartNumber, error: Error)

    var number: Int {
        switch self {
        case .queued(let number),
                .started(let number, _),
                .progressUpdated(let number, _, _, _),
                .completed(let number, _, _),
                .failed(let number, _):
            return number
        }
    }

    var taskIdentifier: TaskIdentifier? {
        let result: Int? = switch self {
        case .started(_, let taskIdentifier),
                .progressUpdated(_, _, let taskIdentifier, _),
                .completed(_, _, let taskIdentifier):
            taskIdentifier
        default:
            nil
        }
        return result
    }

    var isCompleted: Bool {
        let result = if case .completed = self {
            true
        } else {
            false
        }
        return result
    }

    var error: Error? {
        let result: Error? = if case .failed(_, let error) = self {
            error
        } else {
            nil
        }
        return result
    }

}
