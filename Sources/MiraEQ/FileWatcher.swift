import Foundation

/// Observes an existing path. It never creates, deletes, or rewrites user files.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var retryTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        stop()
        attach(generation: generation)
    }

    func stop() {
        generation &+= 1
        retryTask?.cancel()
        retryTask = nil
        source?.cancel()
        source = nil
    }

    private func attach(generation: UInt64) {
        guard generation == self.generation else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            retryAttach(generation: generation)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, generation == self.generation, let source else { return }
            if !source.data.intersection([.delete, .rename]).isEmpty {
                source.cancel()
                self.source = nil
                self.retryAttach(generation: generation)
            }
            self.onChange()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func retryAttach(generation: UInt64) {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.attach(generation: generation)
            // The replacement can appear after the original rename event.
            if self.source != nil { self.onChange() }
        }
    }

    deinit {
        retryTask?.cancel()
        source?.cancel()
    }
}
