import CoreServices

extension FSEventStreamContext {
    static func retaining(_ object: AnyObject) -> FSEventStreamContext {
        FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(object).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<AnyObject>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<AnyObject>.fromOpaque(info).release()
            },
            copyDescription: nil)
    }
}
