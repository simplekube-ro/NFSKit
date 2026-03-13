//
//  NFSEventLoop.swift
//  NFSKit
//
//  Core event loop for pipelined NFS operations. Owns the nfs_context*,
//  manages DispatchSources for I/O readiness, maintains a continuation
//  registry, and routes all NFS operations through an adaptive pipeline.
//
//  Thread Safety: All mutable state is confined to the serial `queue`.
//  The class is marked `@unchecked Sendable` because the DispatchQueue
//  serialisation guarantee cannot be expressed to the compiler.
//

import Foundation
import nfs

// MARK: - Sendable Pointer Wrapper

/// Wrapper that opts a raw pointer into Sendable.
/// Safe when the pointer's lifetime is managed by the event loop's serial queue.
struct SendableRawPointer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

// MARK: - NFSEventLoop

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSEventLoop: @unchecked Sendable {

    // MARK: - Nested Types

    /// Represents an operation waiting to be issued on the event loop.
    struct PendingOperation: @unchecked Sendable {
        let id: UInt64
        let type: OperationType
        let execute: (UnsafeMutablePointer<nfs_context>) -> Int32
    }

    /// Callback data stored in a heap-allocated object. A pointer to this
    /// instance is passed as `private_data` to nfs_*_async via `Unmanaged`.
    ///
    /// The `dataHandler` receives both the NFS callback status code and the
    /// data pointer. For most operations, status == 0 means success. For
    /// read/write operations, status > 0 is the byte count.
    final class CallbackData: @unchecked Sendable {
        let continuationID: UInt64
        let operationCategory: OperationCategory
        let startTime: DispatchTime

        /// Handler that extracts the result from the C callback parameters.
        /// Receives (status, data_pointer). For read: status > 0 is byte count.
        let dataHandler: (Int32, UnsafeMutableRawPointer?) -> Result<Any, Error>

        /// The underlying resume closure. Use `tryResume(_:)` to avoid double-resume.
        private let _resume: (Result<Any, Error>) -> Void

        /// Guards against double-resume (e.g. callback fires during nfs_destroy_context
        /// after shutdown already resumed the continuation).
        private var hasResumed = false

        /// Called on the event loop queue after the callback fires.
        let completionHook: (_ success: Bool) -> Void

        init(
            continuationID: UInt64,
            operationCategory: OperationCategory = .metadata,
            dataHandler: @escaping (Int32, UnsafeMutableRawPointer?) -> Result<Any, Error>,
            resume: @escaping (Result<Any, Error>) -> Void,
            completionHook: @escaping (_ success: Bool) -> Void = { _ in }
        ) {
            self.continuationID = continuationID
            self.operationCategory = operationCategory
            self.startTime = .now()
            self.dataHandler = dataHandler
            self._resume = resume
            self.completionHook = completionHook
        }

        /// Resume the continuation exactly once. Subsequent calls are no-ops.
        func resume(_ result: Result<Any, Error>) {
            guard !hasResumed else { return }
            hasResumed = true
            _resume(result)
        }
    }

    // MARK: - Properties

    private let queue: DispatchQueue
    private var context: UnsafeMutablePointer<nfs_context>?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var currentFd: Int32 = -1
    private var currentSocketIno: UInt64 = 0
    private var timeoutTimer: DispatchSourceTimer?
    private var writeSourceSuspended = true
    private var bulkController = PipelineController()
    private var metadataController = PipelineController()
    private var pendingOperations: [PendingOperation] = []
    private var _inFlightCount: [OperationCategory: Int] = [.bulk: 0, .metadata: 0]
    private var handleRegistry: [UInt64: UnsafeMutablePointer<nfsfh>] = [:]
    private var nextHandleID: UInt64 = 1
    private var isRunning = false
    private let timeout: TimeInterval
    private var activeContinuations: [UInt64: CallbackData] = [:]
    private var nextContinuationID: UInt64 = 1

    // MARK: - Initialisation

    init(timeout: TimeInterval) throws {
        self.timeout = timeout
        self.queue = DispatchQueue(label: "nfs.eventloop", qos: .default)
        self.context = try nfs_init_context().unwrap()
    }

    deinit {
        performShutdown()
    }

    // MARK: - Public Accessors (test support)

    var pipelineDepths: (bulk: Int, metadata: Int) {
        queue.sync {
            (bulkController.effectiveDepth, metadataController.effectiveDepth)
        }
    }

    var inFlightCounts: [OperationCategory: Int] {
        queue.sync { _inFlightCount }
    }

    // MARK: - Lifecycle

    func shutdown() {
        queue.sync {
            performShutdown()
        }
    }

    private func performShutdown() {
        guard context != nil || !activeContinuations.isEmpty else { return }

        isRunning = false
        cancelSources()
        cancelTimeoutTimer()

        let error = POSIXError(.ENOTCONN, description: "Event loop shut down")

        // Snapshot and clear continuations BEFORE destroying the context,
        // since nfs_destroy_context may fire callbacks synchronously.
        let continuations = activeContinuations
        activeContinuations.removeAll()

        pendingOperations.removeAll()

        if let ctx = context {
            for (_, handle) in handleRegistry {
                nfs_close(ctx, handle)
            }
        }
        handleRegistry.removeAll()

        if let ctx = context {
            context = nil
            nfs_destroy_context(ctx)
        }

        // Resume all outstanding continuations with the error.
        // This is done AFTER nfs_destroy_context so that any callbacks
        // that fire during destruction are absorbed by CallbackData.hasResumed.
        for (_, cbData) in continuations {
            cbData.resume(.failure(error))
        }

        bulkController.reset()
        metadataController.reset()
        _inFlightCount = [.bulk: 0, .metadata: 0]
    }

    // MARK: - DispatchSource Setup

    private func setupSources(fd: Int32) {
        cancelSources()
        currentFd = fd
        currentSocketIno = Self.socketIno(fd)
        startTimeoutTimer()

        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in
            self?.handleIOEvent(revents: Int32(POLLIN))
        }
        rs.setCancelHandler { }
        rs.resume()
        readSource = rs

        let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        ws.setEventHandler { [weak self] in
            self?.handleIOEvent(revents: Int32(POLLOUT))
        }
        ws.setCancelHandler { }
        writeSourceSuspended = true
        writeSource = ws
    }

    /// Returns the inode of the socket underlying the given fd.
    /// Used to detect fd reuse: when libnfs closes a socket and opens
    /// a new one that gets the same fd number, kqueue silently removes
    /// the old registration. Without re-creating DispatchSources, the
    /// event loop would never fire again.
    private static func socketIno(_ fd: Int32) -> UInt64 {
        var sb = Darwin.stat()
        guard Darwin.fstat(fd, &sb) == 0 else { return 0 }
        return UInt64(bitPattern: Int64(sb.st_ino))
    }

    private func cancelSources() {
        if let rs = readSource {
            rs.cancel()
            readSource = nil
        }
        if let ws = writeSource {
            if writeSourceSuspended {
                ws.resume()
                writeSourceSuspended = false
            }
            ws.cancel()
            writeSource = nil
        }
        currentFd = -1
        currentSocketIno = 0
    }

    // MARK: - Timeout Timer

    /// Start a periodic timer that checks for timed-out operations.
    /// The old poll()-based event loop had a Swift-level timeout; this
    /// replicates it for the DispatchSource architecture.
    private func startTimeoutTimer() {
        guard timeoutTimer == nil, timeout > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.scanForTimeouts()
        }
        timer.resume()
        timeoutTimer = timer
    }

    private func cancelTimeoutTimer() {
        timeoutTimer?.cancel()
        timeoutTimer = nil
    }

    private func scanForTimeouts() {
        guard timeout > 0 else { return }
        let deadline = DispatchTime.now() - timeout
        var timedOut: [UInt64] = []
        for (contID, cbData) in activeContinuations {
            if cbData.startTime < deadline {
                timedOut.append(contID)
            }
        }
        for contID in timedOut {
            if let cbData = activeContinuations.removeValue(forKey: contID) {
                recordCompletion(category: cbData.operationCategory, success: false)
                cbData.resume(.failure(POSIXError(.ETIMEDOUT)))
            }
        }
    }

    // MARK: - I/O Event Handling

    private func handleIOEvent(revents: Int32) {
        guard let ctx = context else { return }

        let result = nfs_service(ctx, revents)
        if result < 0 {
            let desc = String(cString: nfs_get_error(ctx))
            shutdownWithError(POSIXError(.ENOTCONN, description: desc))
            return
        }

        // Detect socket changes — either a different fd number, or the same
        // fd number backed by a different socket (fd reuse after close+reopen).
        // libnfs closes and re-opens sockets during multi-step mount sequences
        // (portmapper → mountd → nfsd). When the OS reuses the fd number,
        // kqueue silently drops the old registration, so we must re-create
        // DispatchSources to get events on the new socket.
        let newFd = nfs_get_fd(ctx)
        if newFd >= 0 {
            if newFd != currentFd {
                setupSources(fd: newFd)
            } else if Self.socketIno(newFd) != currentSocketIno {
                setupSources(fd: newFd)
            }
        }

        updateWriteSource()
        issuePendingOperations()
    }

    private func updateWriteSource() {
        guard let ctx = context, let ws = writeSource else { return }
        let events = nfs_which_events(ctx)
        if events & Int32(POLLOUT) != 0 {
            if writeSourceSuspended {
                ws.resume()
                writeSourceSuspended = false
            }
        } else {
            if !writeSourceSuspended {
                ws.suspend()
                writeSourceSuspended = true
            }
        }
    }

    private func shutdownWithError(_ error: Error) {
        isRunning = false
        cancelSources()
        cancelTimeoutTimer()

        let continuations = activeContinuations
        activeContinuations.removeAll()
        pendingOperations.removeAll()

        if let ctx = context {
            context = nil
            nfs_destroy_context(ctx)
        }

        for (_, cbData) in continuations {
            cbData.resume(.failure(error))
        }
    }

    // MARK: - Pipeline Slot Management

    private func issuePendingOperations() {
        guard let ctx = context else { return }

        var i = 0
        while i < pendingOperations.count {
            let op = pendingOperations[i]
            let category = op.type.category
            let controller = category == .bulk ? bulkController : metadataController
            let currentInFlight = _inFlightCount[category, default: 0]

            if currentInFlight < controller.effectiveDepth {
                pendingOperations.remove(at: i)
                _inFlightCount[category, default: 0] += 1
                let rc = op.execute(ctx)
                if rc < 0 {
                    _inFlightCount[category, default: 0] -= 1
                }
                updateWriteSource()
            } else {
                i += 1
            }
        }
    }

    private func recordCompletion(category: OperationCategory, success: Bool) {
        _inFlightCount[category, default: 0] = max(0, _inFlightCount[category, default: 0] - 1)
        if category == .bulk {
            if success { bulkController.recordSuccess() } else { bulkController.recordFailure() }
        } else {
            if success { metadataController.recordSuccess() } else { metadataController.recordFailure() }
        }
    }

    private func handleCallbackCompletion(contID: UInt64, category: OperationCategory, success: Bool) {
        activeContinuations.removeValue(forKey: contID)
        recordCompletion(category: category, success: success)
        issuePendingOperations()
    }

    private func errorDescription(_ ctx: UnsafeMutablePointer<nfs_context>) -> String {
        String(cString: nfs_get_error(ctx))
    }

    // MARK: - Submit

    func submit<T: Sendable>(
        type: OperationType,
        dataHandler: @escaping @Sendable (UnsafeMutableRawPointer?) throws -> T,
        execute: @escaping @Sendable (UnsafeMutablePointer<nfs_context>, UnsafeMutableRawPointer) -> Int32
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async { [self] in
                guard let ctx = context else {
                    continuation.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1
                let category = type.category

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: category,
                    dataHandler: { _, ptr in
                        do {
                            let result = try dataHandler(ptr)
                            return .success(result)
                        } catch {
                            return .failure(error)
                        }
                    },
                    resume: { result in
                        switch result {
                        case .success(let value):
                            continuation.resume(returning: value as! T)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: category, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let controller = category == .bulk ? bulkController : metadataController
                let currentInFlight = _inFlightCount[category, default: 0]

                if currentInFlight < controller.effectiveDepth {
                    issueOperation(ctx: ctx, contID: contID, cbData: cbData, type: type, execute: execute)
                } else {
                    let retainedPtr = Unmanaged.passRetained(cbData).toOpaque()
                    let pending = PendingOperation(
                        id: contID,
                        type: type,
                        execute: { ctx in
                            execute(ctx, retainedPtr)
                        }
                    )
                    pendingOperations.append(pending)
                }
            }
        }
    }

    /// Submit with a status-aware data handler (for read/write where error > 0 = byte count).
    func submitWithStatus<T: Sendable>(
        type: OperationType,
        dataHandler: @escaping @Sendable (Int32, UnsafeMutableRawPointer?) throws -> T,
        execute: @escaping @Sendable (UnsafeMutablePointer<nfs_context>, UnsafeMutableRawPointer) -> Int32
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async { [self] in
                guard let ctx = context else {
                    continuation.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1
                let category = type.category

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: category,
                    dataHandler: { status, ptr in
                        do {
                            let result = try dataHandler(status, ptr)
                            return .success(result)
                        } catch {
                            return .failure(error)
                        }
                    },
                    resume: { result in
                        switch result {
                        case .success(let value):
                            continuation.resume(returning: value as! T)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: category, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let controller = category == .bulk ? bulkController : metadataController
                let currentInFlight = _inFlightCount[category, default: 0]

                if currentInFlight < controller.effectiveDepth {
                    issueOperation(ctx: ctx, contID: contID, cbData: cbData, type: type, execute: execute)
                } else {
                    let retainedPtr = Unmanaged.passRetained(cbData).toOpaque()
                    let pending = PendingOperation(
                        id: contID,
                        type: type,
                        execute: { ctx in
                            execute(ctx, retainedPtr)
                        }
                    )
                    pendingOperations.append(pending)
                }
            }
        }
    }

    private func issueOperation(
        ctx: UnsafeMutablePointer<nfs_context>,
        contID: UInt64,
        cbData: CallbackData,
        type: OperationType,
        execute: @escaping (UnsafeMutablePointer<nfs_context>, UnsafeMutableRawPointer) -> Int32
    ) {
        let category = type.category
        let retainedPtr = Unmanaged.passRetained(cbData).toOpaque()
        let rc = execute(ctx, retainedPtr)

        if rc < 0 {
            Unmanaged<CallbackData>.fromOpaque(retainedPtr).release()
            activeContinuations.removeValue(forKey: contID)
            cbData.resume(.failure(POSIXError(.init(Int32(-rc)), description: errorDescription(ctx))))
        } else {
            _inFlightCount[category, default: 0] += 1
            updateWriteSource()
        }
    }

    // MARK: - C Callbacks

    /// The C callback for NFS operations.
    /// Called by nfs_service() on the event loop queue.
    ///
    /// The status parameter semantics vary by operation:
    /// - Most operations: < 0 = error, 0 = success
    /// - Read: > 0 = bytes read, 0 = EOF, < 0 = error
    /// - Write: > 0 = bytes written, < 0 = error
    ///
    /// The dataHandler receives (status, data_pointer) so it can interpret
    /// the status correctly per operation type.
    static let nfsCallback: nfs_cb = { status, nfsCtx, data, privateData in
        guard let privateData = privateData else { return }
        let cbData = Unmanaged<CallbackData>.fromOpaque(privateData).takeRetainedValue()

        if status < 0 {
            cbData.completionHook(false)
            cbData.resume(.failure(POSIXError(.init(Int32(-status)))))
        } else {
            // status >= 0: success. For read/write, status is the byte count.
            // The dataHandler knows how to interpret this.
            let result = cbData.dataHandler(status, data)
            let success: Bool
            switch result {
            case .success: success = true
            case .failure: success = false
            }
            cbData.completionHook(success)
            cbData.resume(result)
        }
    }

    /// The C callback for RPC operations (getexports).
    static let rpcCallback: rpc_cb = { rpc, status, data, privateData in
        guard let privateData = privateData else { return }
        let cbData = Unmanaged<CallbackData>.fromOpaque(privateData).takeRetainedValue()

        if status != 0 {
            cbData.completionHook(false)
            cbData.resume(.failure(POSIXError(.init(status))))
        } else {
            let result = cbData.dataHandler(status, data)
            let success: Bool
            switch result {
            case .success: success = true
            case .failure: success = false
            }
            cbData.completionHook(success)
            cbData.resume(result)
        }
    }

    // MARK: - NFS Operations: Connectivity

    func mount(server: String, export: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let ctx = context else {
                    continuation.resume(throwing: POSIXError(.ENOTCONN, description: "Context not initialized"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .metadata,
                    dataHandler: { _, _ in .success(()) },
                    resume: { result in
                        switch result {
                        case .success:
                            continuation.resume()
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .metadata, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let retainedPtr = Unmanaged.passRetained(cbData).toOpaque()
                let rc = nfs_mount_async(ctx, server, export, NFSEventLoop.nfsCallback, retainedPtr)

                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(retainedPtr).release()
                    activeContinuations.removeValue(forKey: contID)
                    continuation.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                    return
                }

                let fd = nfs_get_fd(ctx)
                if fd >= 0 {
                    setupSources(fd: fd)
                    isRunning = true
                    updateWriteSource()
                } else {
                    // nfs_mount_async succeeded but no fd is available.
                    // The timeout timer (started by setupSources on first
                    // valid fd, or here as a fallback) will eventually
                    // resume the continuation with ETIMEDOUT.
                    startTimeoutTimer()
                }
            }
        }
    }

    func unmount() async throws {
        let _: Void = try await submit(type: .umount, dataHandler: { _ in }) { ctx, cbPtr in
            nfs_umount_async(ctx, NFSEventLoop.nfsCallback, cbPtr)
        }
    }

    func getexports(server: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            queue.async { [self] in
                guard let ctx = context else {
                    continuation.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .metadata,
                    dataHandler: { _, data in
                        guard let data = data else { return .success([String]()) }
                        let result = data.assumingMemoryBound(to: exports.self).pointee
                        var export: exportnode? = result.pointee
                        var list: [String] = []
                        while export != nil {
                            if let dir = export?.ex_dir {
                                list.append(String(cString: dir))
                            }
                            export = export?.ex_next?.pointee
                        }
                        return .success(list)
                    },
                    resume: { result in
                        switch result {
                        case .success(let value):
                            continuation.resume(returning: value as! [String])
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .metadata, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let rpc = nfs_get_rpc_context(ctx)
                let retainedPtr = Unmanaged.passRetained(cbData).toOpaque()
                let rc = mount_getexports_async(rpc, server, NFSEventLoop.rpcCallback, retainedPtr)

                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(retainedPtr).release()
                    activeContinuations.removeValue(forKey: contID)
                    continuation.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                }
            }
        }
    }

    // MARK: - NFS Operations: File Information

    func stat(_ path: String) async throws -> nfs_stat_64 {
        try await submit(type: .stat, dataHandler: { ptr in
            try ptr.unwrap().assumingMemoryBound(to: nfs_stat_64.self).pointee
        }) { ctx, cbPtr in
            nfs_stat64_async(ctx, path, NFSEventLoop.nfsCallback, cbPtr)
        }
    }

    func statvfs(_ path: String) async throws -> nfs.statvfs {
        let result: nfs.statvfs = try await submit(type: .stat, dataHandler: { ptr in
            try ptr.unwrap().assumingMemoryBound(to: nfs.statvfs.self).pointee
        }) { ctx, cbPtr in
            nfs_statvfs_async(ctx, path, NFSEventLoop.nfsCallback, cbPtr)
        }
        return result
    }

    func readlink(_ path: String) async throws -> String {
        try await submit(type: .readlink, dataHandler: { ptr in
            try String(cString: ptr.unwrap().assumingMemoryBound(to: Int8.self))
        }) { ctx, cbPtr in
            nfs_readlink_async(ctx, path, NFSEventLoop.nfsCallback, cbPtr)
        }
    }

    // MARK: - NFS Operations: Directory

    func mkdir(_ path: String) async throws {
        let _: Void = try await submit(type: .mkdir, dataHandler: { _ in }) { ctx, cbPtr in
            nfs_mkdir_async(ctx, path, NFSEventLoop.nfsCallback, cbPtr)
        }
    }

    func rmdir(_ path: String) async throws {
        let _: Void = try await submit(type: .rmdir, dataHandler: { _ in }) { ctx, cbPtr in
            nfs_rmdir_async(ctx, path, NFSEventLoop.nfsCallback, cbPtr)
        }
    }

    func opendir(_ path: String) async throws -> SendableRawPointer {
        try await submit(type: .opendir, dataHandler: { ptr in
            SendableRawPointer(pointer: try ptr.unwrap())
        }) { ctx, cbPtr in
            nfs_opendir_async(ctx, path, NFSEventLoop.nfsCallback, cbPtr)
        }
    }

    // MARK: - NFS Operations: File Manipulation

    func unlink(_ path: String) async throws {
        let _: Void = try await submit(type: .unlink, dataHandler: { _ in }) { ctx, cbPtr in
            nfs_unlink_async(ctx, path, NFSEventLoop.nfsCallback, cbPtr)
        }
    }

    func rename(_ path: String, to newPath: String) async throws {
        let _: Void = try await submit(type: .rename, dataHandler: { _ in }) { ctx, cbPtr in
            nfs_rename_async(ctx, path, newPath, NFSEventLoop.nfsCallback, cbPtr)
        }
    }

    func truncate(_ path: String, toLength: UInt64) async throws {
        let _: Void = try await submit(type: .truncate, dataHandler: { _ in }) { ctx, cbPtr in
            nfs_truncate_async(ctx, path, toLength, NFSEventLoop.nfsCallback, cbPtr)
        }
    }

    // MARK: - NFS Operations: File Handles

    func openFile(_ path: String, flags: Int32) async throws -> UInt64 {
        let wrapper: SendableRawPointer = try await submit(type: .open, dataHandler: { ptr in
            SendableRawPointer(pointer: try ptr.unwrap())
        }) { ctx, cbPtr in
            nfs_open_async(ctx, path, flags, NFSEventLoop.nfsCallback, cbPtr)
        }

        return await withCheckedContinuation { cont in
            queue.async { [self] in
                let handleID = nextHandleID
                nextHandleID += 1
                handleRegistry[handleID] = wrapper.pointer.assumingMemoryBound(to: nfsfh.self)
                cont.resume(returning: handleID)
            }
        }
    }

    func closeFile(handleID: UInt64) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let handle = handleRegistry[handleID] else {
                    cont.resume(throwing: POSIXError(.EBADF, description: "Invalid file handle"))
                    return
                }
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .metadata,
                    dataHandler: { _, _ in .success(()) },
                    resume: { result in
                        switch result {
                        case .success: cont.resume()
                        case .failure(let error): cont.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .metadata, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                handleRegistry.removeValue(forKey: handleID)

                let ptr = Unmanaged.passRetained(cbData).toOpaque()
                let rc = nfs_close_async(ctx, handle, NFSEventLoop.nfsCallback, ptr)
                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(ptr).release()
                    activeContinuations.removeValue(forKey: contID)
                    cont.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                } else {
                    _inFlightCount[.metadata, default: 0] += 1
                    updateWriteSource()
                }
            }
        }
    }

    /// Read data from an open file handle.
    /// For read callbacks: status > 0 is byte count, == 0 is EOF, < 0 is error.
    func readFile(handleID: UInt64, count: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async { [self] in
                guard let handle = handleRegistry[handleID] else {
                    cont.resume(throwing: POSIXError(.EBADF, description: "Invalid file handle"))
                    return
                }
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                // For read, status > 0 means bytes read. The static nfsCallback
                // passes status >= 0 to dataHandler, which interprets it.
                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .bulk,
                    dataHandler: { status, dataPtr in
                        if status > 0 {
                            let byteCount = Int(status)
                            if let dataPtr = dataPtr {
                                return .success(Data(bytes: dataPtr, count: byteCount))
                            }
                            return .success(Data())
                        }
                        // status == 0 means EOF
                        return .success(Data())
                    },
                    resume: { result in
                        switch result {
                        case .success(let value):
                            cont.resume(returning: value as! Data)
                        case .failure(let error):
                            cont.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .bulk, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let retainedPtr = Unmanaged.passRetained(cbData).toOpaque()
                let rc = nfs_read_async(ctx, handle, count, NFSEventLoop.nfsCallback, retainedPtr)
                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(retainedPtr).release()
                    activeContinuations.removeValue(forKey: contID)
                    cont.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                } else {
                    _inFlightCount[.bulk, default: 0] += 1
                    updateWriteSource()
                }
            }
        }
    }

    /// Write data to an open file handle.
    /// For write callbacks: status > 0 is bytes written, < 0 is error.
    func writeFile(handleID: UInt64, data writeData: Data) async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            queue.async { [self] in
                guard let handle = handleRegistry[handleID] else {
                    cont.resume(throwing: POSIXError(.EBADF, description: "Invalid file handle"))
                    return
                }
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .bulk,
                    dataHandler: { status, _ in
                        return .success(Int(status))
                    },
                    resume: { result in
                        switch result {
                        case .success(let value):
                            cont.resume(returning: value as! Int)
                        case .failure(let error):
                            cont.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .bulk, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let retainedPtr = Unmanaged.passRetained(cbData).toOpaque()
                let buffer = Array(writeData)
                let rc = buffer.withUnsafeBufferPointer { bufPtr in
                    nfs_write_async(ctx, handle, UInt64(buffer.count), bufPtr.baseAddress, NFSEventLoop.nfsCallback, retainedPtr)
                }
                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(retainedPtr).release()
                    activeContinuations.removeValue(forKey: contID)
                    cont.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                } else {
                    _inFlightCount[.bulk, default: 0] += 1
                    updateWriteSource()
                }
            }
        }
    }

    /// Positional read from a file handle.
    func preadFile(handleID: UInt64, offset: UInt64, count: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async { [self] in
                guard let handle = handleRegistry[handleID] else {
                    cont.resume(throwing: POSIXError(.EBADF, description: "Invalid file handle"))
                    return
                }
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .bulk,
                    dataHandler: { status, dataPtr in
                        if status > 0 {
                            let byteCount = Int(status)
                            if let dataPtr = dataPtr {
                                return .success(Data(bytes: dataPtr, count: byteCount))
                            }
                            return .success(Data())
                        }
                        return .success(Data())
                    },
                    resume: { result in
                        switch result {
                        case .success(let value):
                            cont.resume(returning: value as! Data)
                        case .failure(let error):
                            cont.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .bulk, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let retainedPtr = Unmanaged.passRetained(cbData).toOpaque()
                let rc = nfs_pread_async(ctx, handle, offset, count, NFSEventLoop.nfsCallback, retainedPtr)
                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(retainedPtr).release()
                    activeContinuations.removeValue(forKey: contID)
                    cont.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                } else {
                    _inFlightCount[.bulk, default: 0] += 1
                    updateWriteSource()
                }
            }
        }
    }

    /// Positional write to a file handle.
    func pwriteFile(handleID: UInt64, offset: UInt64, data writeData: Data) async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            queue.async { [self] in
                guard let handle = handleRegistry[handleID] else {
                    cont.resume(throwing: POSIXError(.EBADF, description: "Invalid file handle"))
                    return
                }
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .bulk,
                    dataHandler: { status, _ in
                        return .success(Int(status))
                    },
                    resume: { result in
                        switch result {
                        case .success(let value):
                            cont.resume(returning: value as! Int)
                        case .failure(let error):
                            cont.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .bulk, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let retainedPtr = Unmanaged.passRetained(cbData).toOpaque()
                let buffer = Array(writeData)
                let rc = buffer.withUnsafeBufferPointer { bufPtr in
                    nfs_pwrite_async(ctx, handle, offset, UInt64(buffer.count), bufPtr.baseAddress, NFSEventLoop.nfsCallback, retainedPtr)
                }
                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(retainedPtr).release()
                    activeContinuations.removeValue(forKey: contID)
                    cont.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                } else {
                    _inFlightCount[.bulk, default: 0] += 1
                    updateWriteSource()
                }
            }
        }
    }

    /// Sync a file handle to disk.
    func fsync(handleID: UInt64) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let handle = handleRegistry[handleID] else {
                    cont.resume(throwing: POSIXError(.EBADF, description: "Invalid file handle"))
                    return
                }
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .metadata,
                    dataHandler: { _, _ in .success(()) },
                    resume: { result in
                        switch result {
                        case .success: cont.resume()
                        case .failure(let error): cont.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .metadata, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let ptr = Unmanaged.passRetained(cbData).toOpaque()
                let rc = nfs_fsync_async(ctx, handle, NFSEventLoop.nfsCallback, ptr)
                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(ptr).release()
                    activeContinuations.removeValue(forKey: contID)
                    cont.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                } else {
                    _inFlightCount[.metadata, default: 0] += 1
                    updateWriteSource()
                }
            }
        }
    }

    /// Get file status from a handle.
    func fstat(handleID: UInt64) async throws -> nfs_stat_64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<nfs_stat_64, Error>) in
            queue.async { [self] in
                guard let handle = handleRegistry[handleID] else {
                    cont.resume(throwing: POSIXError(.EBADF, description: "Invalid file handle"))
                    return
                }
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .metadata,
                    dataHandler: { _, ptr in
                        guard let ptr = ptr else { return .failure(POSIXError(.ENODATA)) }
                        return .success(ptr.assumingMemoryBound(to: nfs_stat_64.self).pointee)
                    },
                    resume: { result in
                        switch result {
                        case .success(let value):
                            cont.resume(returning: value as! nfs_stat_64)
                        case .failure(let error):
                            cont.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .metadata, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let ptr = Unmanaged.passRetained(cbData).toOpaque()
                let rc = nfs_fstat64_async(ctx, handle, NFSEventLoop.nfsCallback, ptr)
                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(ptr).release()
                    activeContinuations.removeValue(forKey: contID)
                    cont.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                } else {
                    _inFlightCount[.metadata, default: 0] += 1
                    updateWriteSource()
                }
            }
        }
    }

    /// Truncate a file via its handle.
    func ftruncate(handleID: UInt64, toLength: UInt64) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let handle = handleRegistry[handleID] else {
                    cont.resume(throwing: POSIXError(.EBADF, description: "Invalid file handle"))
                    return
                }
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .metadata,
                    dataHandler: { _, _ in .success(()) },
                    resume: { result in
                        switch result {
                        case .success: cont.resume()
                        case .failure(let error): cont.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .metadata, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let ptr = Unmanaged.passRetained(cbData).toOpaque()
                let rc = nfs_ftruncate_async(ctx, handle, toLength, NFSEventLoop.nfsCallback, ptr)
                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(ptr).release()
                    activeContinuations.removeValue(forKey: contID)
                    cont.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                } else {
                    _inFlightCount[.metadata, default: 0] += 1
                    updateWriteSource()
                }
            }
        }
    }

    /// Seek within a file handle.
    func lseek(handleID: UInt64, offset: Int64, whence: Int32) async throws -> UInt64 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
            queue.async { [self] in
                guard let handle = handleRegistry[handleID] else {
                    cont.resume(throwing: POSIXError(.EBADF, description: "Invalid file handle"))
                    return
                }
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let contID = nextContinuationID
                nextContinuationID += 1

                let cbData = CallbackData(
                    continuationID: contID,
                    operationCategory: .metadata,
                    dataHandler: { _, ptr in
                        guard let ptr = ptr else { return .success(UInt64(0)) }
                        return .success(ptr.assumingMemoryBound(to: UInt64.self).pointee)
                    },
                    resume: { result in
                        switch result {
                        case .success(let value):
                            cont.resume(returning: value as! UInt64)
                        case .failure(let error):
                            cont.resume(throwing: error)
                        }
                    },
                    completionHook: { [weak self] success in
                        self?.handleCallbackCompletion(contID: contID, category: .metadata, success: success)
                    }
                )

                activeContinuations[contID] = cbData

                let ptr = Unmanaged.passRetained(cbData).toOpaque()
                let rc = nfs_lseek_async(ctx, handle, offset, whence, NFSEventLoop.nfsCallback, ptr)
                if rc < 0 {
                    Unmanaged<CallbackData>.fromOpaque(ptr).release()
                    activeContinuations.removeValue(forKey: contID)
                    cont.resume(throwing: POSIXError(.init(Int32(-rc)), description: errorDescription(ctx)))
                } else {
                    _inFlightCount[.metadata, default: 0] += 1
                    updateWriteSource()
                }
            }
        }
    }

    // MARK: - Fire-and-Forget Close

    /// Close a file handle without awaiting the result.
    /// Used from NFSFileHandle.deinit where `await` is not available.
    func closeFileFireAndForget(handleID: UInt64) {
        queue.async { [self] in
            guard let handle = handleRegistry.removeValue(forKey: handleID),
                  let ctx = context else { return }
            nfs_close(ctx, handle)
        }
    }

    // MARK: - Directory Reading

    /// Read all directory entries synchronously on the event loop queue.
    /// The directory is closed after reading.
    func readdirAll(dirPtr: SendableRawPointer, path: String) async throws -> [[URLResourceKey: Any]] {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                guard let ctx = context else {
                    cont.resume(throwing: POSIXError(.ENOTCONN, description: "Not connected"))
                    return
                }

                let dir = dirPtr.pointer.assumingMemoryBound(to: nfsdir.self)
                var entries: [[URLResourceKey: Any]] = []

                while let ent = nfs_readdir(ctx, dir) {
                    let name = String(cString: ent.pointee.name)
                    guard name != "." && name != ".." else { continue }

                    var dic: [URLResourceKey: Any] = [:]
                    dic[.nameKey] = name
                    dic[.pathKey] = path.hasSuffix("/") ? path + name : path + "/" + name
                    dic[.fileSizeKey] = Int64(ent.pointee.size)
                    dic[.linkCountKey] = NSNumber(value: ent.pointee.nlink)

                    switch ent.pointee.type {
                    case NF3REG.rawValue:
                        dic[.fileResourceTypeKey] = URLFileResourceType.regular
                        dic[.isRegularFileKey] = true
                        dic[.isDirectoryKey] = false
                        dic[.isSymbolicLinkKey] = false
                    case NF3DIR.rawValue:
                        dic[.fileResourceTypeKey] = URLFileResourceType.directory
                        dic[.isDirectoryKey] = true
                        dic[.isRegularFileKey] = false
                        dic[.isSymbolicLinkKey] = false
                    case NF3LNK.rawValue:
                        dic[.fileResourceTypeKey] = URLFileResourceType.symbolicLink
                        dic[.isSymbolicLinkKey] = true
                        dic[.isRegularFileKey] = false
                        dic[.isDirectoryKey] = false
                    default:
                        dic[.fileResourceTypeKey] = URLFileResourceType.unknown
                        dic[.isRegularFileKey] = false
                        dic[.isDirectoryKey] = false
                        dic[.isSymbolicLinkKey] = false
                    }

                    dic[.contentModificationDateKey] = Date(
                        timespec(
                            tv_sec: Int(ent.pointee.mtime.tv_sec),
                            tv_nsec: Int(ent.pointee.mtime.tv_usec) * 1000
                        )
                    )
                    dic[.contentAccessDateKey] = Date(
                        timespec(
                            tv_sec: Int(ent.pointee.atime.tv_sec),
                            tv_nsec: Int(ent.pointee.atime.tv_usec) * 1000
                        )
                    )
                    dic[.creationDateKey] = Date(
                        timespec(
                            tv_sec: Int(ent.pointee.ctime.tv_sec),
                            tv_nsec: Int(ent.pointee.ctime.tv_usec) * 1000
                        )
                    )

                    entries.append(dic)
                }

                nfs_closedir(ctx, dir)
                cont.resume(returning: entries)
            }
        }
    }

    // MARK: - Performance Tuning (pre-connect)

    func setReadMax(_ bytes: UInt64) throws {
        try queue.sync {
            let ctx = try context.unwrap()
            nfs_set_readmax(ctx, bytes)
        }
    }

    func setReadAhead(_ bytes: UInt32) throws {
        try queue.sync {
            let ctx = try context.unwrap()
            nfs_set_readahead(ctx, bytes)
        }
    }

    func setPageCache(pages: UInt32, ttl: UInt32 = 30) throws {
        try queue.sync {
            let ctx = try context.unwrap()
            nfs_set_pagecache(ctx, pages)
            nfs_set_pagecache_ttl(ctx, ttl)
        }
    }

    @discardableResult
    func setVersion(_ version: Int32) throws -> Int32 {
        try queue.sync {
            let ctx = try context.unwrap()
            return nfs_set_version(ctx, version)
        }
    }

    func getVersion() throws -> Int32 {
        try queue.sync {
            let ctx = try context.unwrap()
            return nfs_get_version(ctx)
        }
    }

    func setAutoReconnect(_ retries: Int32) throws {
        try queue.sync {
            let ctx = try context.unwrap()
            nfs_set_autoreconnect(ctx, retries)
        }
    }

    func setUID(_ uid: Int32) throws {
        try queue.sync {
            let ctx = try context.unwrap()
            nfs_set_uid(ctx, uid)
        }
    }

    func setGID(_ gid: Int32) throws {
        try queue.sync {
            let ctx = try context.unwrap()
            nfs_set_gid(ctx, gid)
        }
    }
}

// MARK: - Result Extension

extension Result {
    var isSuccess: Bool {
        switch self {
        case .success: return true
        case .failure: return false
        }
    }
}
