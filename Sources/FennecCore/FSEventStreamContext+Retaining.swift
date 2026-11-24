import CoreServices

extension FSEventStreamContext {
    static func retaining(_ object: AnyObject) -> FSEventStreamContext {
        FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(object).toOpaque(), // lint-allow: the retain callback below owns the reference, expires 2027-11-23, approved-by bvdwalt
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
