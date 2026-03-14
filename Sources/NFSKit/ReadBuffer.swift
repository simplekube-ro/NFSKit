import Foundation

/// ARC-managed wrapper for an unsafe read buffer. Allocates memory on init,
/// deallocates on deinit unless `disown()` has been called to transfer ownership.
///
/// Used by NFSEventLoop to provide caller-owned buffers to libnfs 6.x's
/// zero-copy read API. The buffer is captured in the read callback closure;
/// on success, ownership transfers to `Data(bytesNoCopy:deallocator:)` via `disown()`.
/// On error, ARC releases this object and deinit frees the memory.
final class ReadBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    let size: Int
    private(set) var isOwned: Bool = true

    init(byteCount: Int) {
        self.pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1)
        self.size = byteCount
    }

    /// Transfer ownership of the pointer. After calling this, deinit will NOT deallocate.
    func disown() {
        isOwned = false
    }

    deinit {
        if isOwned {
            pointer.deallocate()
        }
    }
}
