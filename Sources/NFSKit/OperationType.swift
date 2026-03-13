//
//  OperationType.swift
//  NFSKit
//
//  Classifies NFS operations for pipeline routing.
//

/// Categorizes NFS operations for pipeline controller selection.
enum OperationCategory: Sendable {
    /// Bulk data transfer operations: read, pread, write, pwrite.
    case bulk
    /// All other operations (stat, mkdir, open, etc.).
    case metadata
}

/// All NFS operation types supported by the event loop.
enum OperationType: Sendable {
    case read, pread, write, pwrite
    case stat, statvfs, readlink
    case mkdir, rmdir, unlink, rename, truncate
    case open, close, fsync
    case opendir
    case mount, umount

    /// The pipeline category this operation belongs to.
    var category: OperationCategory {
        switch self {
        case .read, .pread, .write, .pwrite:
            return .bulk
        default:
            return .metadata
        }
    }
}
