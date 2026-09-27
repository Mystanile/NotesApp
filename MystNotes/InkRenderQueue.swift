import Foundation

/// Where off-screen ink is drawn: one serial dispatch queue, never Swift's
/// cooperative thread pool.
///
/// `PKDrawing.image(from:scale:)` blocks its thread while PencilKit draws
/// through Metal, and PencilKit's first textured render sets up a paper
/// texture with a synchronous `MTKTextureLoader` call that waits on work of
/// its own - while holding PencilKit's resource lock. Run from
/// `Task.detached`, one thumbnail per page all at once, eight renders filled
/// the iPad's eight cooperative threads: one holding the lock and waiting
/// for the texture, seven waiting for the lock, and nothing left to finish
/// the texture. Every ink render in the app deadlocked behind it - every
/// page and thumbnail blank, for good (Sept 27, 2026; found with a spindump
/// on the device, never seen in the simulator).
///
/// Here a render blocks a thread of this queue, which the pool never
/// needs, and renders never overlap inside PencilKit. Callers await it,
/// which suspends rather than blocks.
nonisolated enum InkRenderQueue {
    private static let queue = DispatchQueue(label: "MystNotes.InkRender", qos: .userInitiated)

    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
