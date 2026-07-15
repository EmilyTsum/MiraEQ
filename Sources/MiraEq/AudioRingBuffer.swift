import Foundation
import Atomics

/// Lock-free SPSC ring buffer for bridging IOProc (producer) to AVAudioEngine (consumer).
/// Power-of-2 capacity, wrapping integer arithmetic for correctness.
public final class AudioRingBuffer: @unchecked Sendable {
    private static let maximumCapacitySamples = 1 << 24

    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private let _writeHead = ManagedAtomic<UInt64>(0)
    private let _readHead = ManagedAtomic<UInt64>(0)

    public init(capacityFrames: Int, channels: Int) {
        let safeFrames = max(capacityFrames, 1)
        let safeChannels = max(channels, 1)
        let requestedCapacity = safeFrames > Int.max / safeChannels ? Int.max : safeFrames * safeChannels
        let cap = min(requestedCapacity, Self.maximumCapacitySamples)
        var power = 1
        while power < cap && power <= Int.max / 2 { power *= 2 }
        self.capacity = power
        self.mask = power - 1
        self.buffer = .allocate(capacity: power)
        self.buffer.initialize(repeating: 0.0, count: power)
    }

    public var capacitySamples: Int {
        capacity
    }

    deinit {
        buffer.deallocate()
    }

    public var availableToRead: Int {
        let w = _writeHead.load(ordering: .relaxed)
        let r = _readHead.load(ordering: .relaxed)
        return Int(w &- r)
    }

    @discardableResult
    public func write(_ data: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        var w = _writeHead.load(ordering: .relaxed)
        let r = _readHead.load(ordering: .acquiring)
        let available = min(w &- r, UInt64(capacity))
        let freeSpace = capacity - Int(available)
        let toWrite = min(count, freeSpace)
        guard toWrite > 0 else { return count }

        for i in 0..<toWrite {
            buffer[Int(w) & mask] = data[i]
            w &+= 1
        }
        _writeHead.store(w, ordering: .releasing)
        return count - toWrite
    }

    public func read(_ dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }

        let w = _writeHead.load(ordering: .acquiring)
        var r = _readHead.load(ordering: .relaxed)
        let avail = Int(w &- r)
        let toRead = min(count, avail)
        for i in 0..<toRead {
            dest[i] = buffer[Int(r) & mask]
            r &+= 1
        }
        _readHead.store(r, ordering: .releasing)
        return toRead
    }

    @discardableResult
    public func trimToLatest(maxSamples: Int) -> Int {
        guard maxSamples > 0 else { return 0 }

        let w = _writeHead.load(ordering: .acquiring)
        let r = _readHead.load(ordering: .relaxed)
        let available = Int(w &- r)
        if available > maxSamples {
            let dropped = available - maxSamples
            _readHead.store(w &- UInt64(maxSamples), ordering: .releasing)
            return dropped
        }
        return 0
    }
}
