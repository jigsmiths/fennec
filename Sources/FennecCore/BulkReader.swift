import Darwin

final class BulkReader {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let isHidden: Bool
        var modified: Int64 = 0
        var isMountPoint = false
        var size: Int64 = 0
        var allocated: Int64 = 0
    }

    enum Outcome { case finished, stopped, failed }

    private static let bufferSize = 64 * 1024
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
    private let details: Bool
    private var attributes = attrlist()

    init(details: Bool = false) {
        self.details = details
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_FLAGS)
        if details {
            attributes.commonattr |= attrgroup_t(ATTR_CMN_MODTIME)
            attributes.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
            attributes.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        }
    }

    deinit { buffer.deallocate() }

    func list(_ path: String, entry: (Entry) -> Bool) -> Outcome {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return .failed }
        defer { close(fd) }

        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, Self.bufferSize, UInt64(FSOPT_PACK_INVAL_ATTRS))
            if count == 0 { return .finished }
            if count < 0 { return .failed }
            var record = buffer
            for _ in 0..<count {
                let length = record.loadUnaligned(as: UInt32.self)
                if !entry(parse(record)) { return .stopped }
                record += Int(length)
            }
        }
    }

    /// Attributes come back in bit order within each group (common, then directory, then file). Even with
    /// FSOPT_PACK_INVAL_ATTRS, directory attributes are left out for files and file attributes for folders,
    /// so the returned set says which are there.
    private func parse(_ record: UnsafeMutableRawPointer) -> Entry {
        let returned = (record + MemoryLayout<UInt32>.size).loadUnaligned(as: attribute_set_t.self)
        var field = record + MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
        let nameRef = field.loadUnaligned(as: attrreference_t.self)
        let name = String(cString: (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
        field += MemoryLayout<attrreference_t>.size
        let type = field.loadUnaligned(as: fsobj_type_t.self)
        field += MemoryLayout<fsobj_type_t>.size
        var modified: Int64 = 0
        if details {
            modified = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
            field += MemoryLayout<timespec>.size
        }
        let flags = field.loadUnaligned(as: UInt32.self)
        field += MemoryLayout<UInt32>.size

        let isDirectory = type == fsobj_type_t(VDIR.rawValue)
        var entry = Entry(
            name: name, isDirectory: isDirectory,
            isHidden: name.hasPrefix(".") || flags & UInt32(UF_HIDDEN) != 0)
        guard details else { return entry }

        entry.modified = modified
        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            let mountStatus = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
            entry.isMountPoint = isDirectory && mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 {
            entry.size = Int64(field.loadUnaligned(as: off_t.self))
            field += MemoryLayout<off_t>.size
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocated = Int64(field.loadUnaligned(as: off_t.self))
        }
        return entry
    }
}
