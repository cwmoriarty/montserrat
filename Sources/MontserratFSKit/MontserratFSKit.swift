import Foundation
import MontserratCore
import CExt2FS
import CLegacyFS
import CAppleExplorer
import CCowFS

public enum FSKitSupport {
    public static var isSupportedOnCurrentOS: Bool {
        #if canImport(FSKit)
        if #available(macOS 15.4, *) {
            return true
        }
        #endif
        return false
    }

    public static func checkAvailability() -> (available: Bool, reason: String) {
        #if canImport(FSKit)
        guard isSupportedOnCurrentOS else {
            return (false, "FSKit requires macOS 15.4 or later.")
        }
        return (true, "FSKit native user-space filesystem framework is available.")
        #else
        return (false, "FSKit requires macOS 15.4 or later (FSKit SDK unavailable at build time).")
        #endif
    }
}

/// Montserrat FSKit Provider coordinating native Apple FSKit vs FUSE-T shims
public final class MontserratFSKitManager: Sendable {
    public static let shared = MontserratFSKitManager()

    public init() {}

    /// Evaluates the preferred mounting engine: Native FSKit or FUSE-T fallback
    public func preferredEngine(for target: String) -> EngineType {
        let availability = FSKitSupport.checkAvailability()
        if availability.available {
            return .fskit
        }
        return .fuseT
    }

    public enum EngineType: String, Sendable {
        case fskit = "Apple FSKit (Native VFS)"
        case fuseT = "FUSE-T (User-space Loopback)"
    }
}

#if canImport(FSKit)
import FSKit

/// Ext4 FSItem holding ext4 inode identity
@available(macOS 15.4, *)
public final class Ext4FSItem: FSItem, @unchecked Sendable {
    public let inodeNumber: UInt64
    public let itemType: UInt8

    public init(inodeNumber: UInt64, itemType: UInt8 = 0) {
        self.inodeNumber = inodeNumber
        self.itemType = itemType
        super.init()
    }
}

@available(macOS 15.4, *)
private final class FSBlockDeviceIOBridge: SuperblockReadable, @unchecked Sendable {
    let resource: FSBlockDeviceResource

    init(resource: FSBlockDeviceResource) {
        self.resource = resource
    }

    func readBytes(offset: UInt64, length: Int) -> Data? {
        guard length > 0 else { return Data() }
        let pbs = max(Int(resource.physicalBlockSize), 512)
        let alignedStart = (Int(offset) / pbs) * pbs
        let end = Int(offset) + length
        let alignedEnd = ((end + pbs - 1) / pbs) * pbs
        let alignedLength = alignedEnd - alignedStart

        var buf = [UInt8](repeating: 0, count: alignedLength)
        do {
            let got = try buf.withUnsafeMutableBytes { rawBuf in
                try resource.read(into: rawBuf, startingAt: off_t(alignedStart), length: alignedLength)
            }
            let innerOff = Int(offset) - alignedStart
            guard got > innerOff else { return nil }
            let available = min(length, got - innerOff)
            return Data(buf[innerOff..<(innerOff + available)])
        } catch {
            return nil
        }
    }

    func writeBytes(offset: UInt64, buffer: UnsafeRawPointer, length: Int) -> Int32 {
        guard length > 0 else { return 0 }
        let pbs = max(Int(resource.physicalBlockSize), 512)
        let alignedStart = (Int(offset) / pbs) * pbs
        let end = Int(offset) + length
        let alignedEnd = ((end + pbs - 1) / pbs) * pbs
        let alignedLength = alignedEnd - alignedStart

        if alignedStart == Int(offset) && alignedLength == length {
            let rawBuf = UnsafeRawBufferPointer(start: buffer, count: length)
            do {
                let put = try resource.write(from: rawBuf, startingAt: off_t(alignedStart), length: length)
                return put == length ? 0 : Int32(-EIO)
            } catch {
                return Int32(-EIO)
            }
        }

        var tmp = [UInt8](repeating: 0, count: alignedLength)
        do {
            _ = try tmp.withUnsafeMutableBytes { rawBuf in
                try resource.read(into: rawBuf, startingAt: off_t(alignedStart), length: alignedLength)
            }
            let innerOff = Int(offset) - alignedStart
            tmp.withUnsafeMutableBytes { rawBuf in
                if let dst = rawBuf.baseAddress {
                    memcpy(dst.advanced(by: innerOff), buffer, length)
                }
            }
            let put = try tmp.withUnsafeBytes { rawBuf in
                try resource.write(from: rawBuf, startingAt: off_t(alignedStart), length: alignedLength)
            }
            return put == alignedLength ? 0 : Int32(-EIO)
        } catch {
            return Int32(-EIO)
        }
    }
}

/// Ext4 Native FSKit Volume implementation
@available(macOS 15.4, *)
public final class Ext4FSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, @unchecked Sendable {
    private var ext4Ctx: OpaquePointer?
    private var ioBridge: FSBlockDeviceIOBridge?
    public let blockResource: FSBlockDeviceResource?
    public let rawDevicePath: String
    public let isReadOnly: Bool

    public init(volumeID: FSVolume.Identifier, volumeName: FSFileName, devicePath: String, readOnly: Bool = false) {
        self.blockResource = nil
        self.rawDevicePath = devicePath
        self.isReadOnly = readOnly
        super.init(volumeID: volumeID, volumeName: volumeName)

        var ctx: OpaquePointer?
        let rc = ext4_bridge_mount(devicePath, readOnly ? 1 : 0, &ctx)
        if rc == 0 {
            self.ext4Ctx = ctx
        }
    }

    public init(volumeID: FSVolume.Identifier, volumeName: FSFileName, resource: FSBlockDeviceResource, readOnly: Bool = false) {
        self.blockResource = resource
        self.rawDevicePath = "/dev/\(resource.bsdName)"
        self.isReadOnly = readOnly || !resource.isWritable
        super.init(volumeID: volumeID, volumeName: volumeName)
        _ = mountViaResource(resource)
    }

    private func mountViaResource(_ resource: FSBlockDeviceResource) -> Int32 {
        let bridge = FSBlockDeviceIOBridge(resource: resource)
        let ctxPtr = Unmanaged.passUnretained(bridge).toOpaque()
        let pbs = UInt32(max(resource.physicalBlockSize, 512))

        let readFn: ext4_io_read_fn = { rawCtx, offset, length, buffer, outRead in
            guard let rawCtx, let buffer else { return Int32(-EINVAL) }
            let box = Unmanaged<FSBlockDeviceIOBridge>.fromOpaque(rawCtx).takeUnretainedValue()
            let rawBuf = UnsafeMutableRawBufferPointer(start: buffer, count: length)
            do {
                let got = try box.resource.read(into: rawBuf, startingAt: off_t(offset), length: length)
                outRead?.pointee = got
                return 0
            } catch {
                return Int32(-EIO)
            }
        }

        let writeFn: ext4_io_write_fn = { rawCtx, offset, length, buffer, outWritten in
            guard let rawCtx, let buffer else { return Int32(-EINVAL) }
            let box = Unmanaged<FSBlockDeviceIOBridge>.fromOpaque(rawCtx).takeUnretainedValue()
            let rawBuf = UnsafeRawBufferPointer(start: buffer, count: length)
            do {
                let put = try box.resource.write(from: rawBuf, startingAt: off_t(offset), length: length)
                outWritten?.pointee = put
                return 0
            } catch {
                return Int32(-EIO)
            }
        }

        let flushFn: ext4_io_flush_fn = { rawCtx in
            guard let rawCtx else { return 0 }
            let box = Unmanaged<FSBlockDeviceIOBridge>.fromOpaque(rawCtx).takeUnretainedValue()
            do {
                try box.resource.metadataFlush()
                return 0
            } catch {
                return Int32(-EIO)
            }
        }

        var ctx: OpaquePointer?
        let rc = resource.bsdName.withCString { cName in
            ext4_bridge_mount_io(
                cName,
                isReadOnly ? 1 : 0,
                pbs,
                ctxPtr,
                readFn,
                isReadOnly ? nil : writeFn,
                flushFn,
                &ctx
            )
        }
        if rc == 0 {
            self.ioBridge = bridge
            self.ext4Ctx = ctx
        }
        return rc
    }

    deinit {
        if let ctx = ext4Ctx {
            ext4_bridge_unmount(ctx)
            ext4Ctx = nil
        }
        ioBridge = nil
    }

    // MARK: - FSVolumeCommonOperations
    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = true
        caps.supportsJournal = true
        caps.supportsActiveJournal = true
        return caps
    }

    public var volumeStatistics: FSStatFSResult {
        let stat = FSStatFSResult(fileSystemTypeName: "ext4")
        guard let ctx = ext4Ctx else {
            stat.blockSize = 4096
            stat.ioSize = 65536
            return stat
        }

        var totalBytes: UInt64 = 0
        var freeBytes: UInt64 = 0
        var bsize: UInt32 = 4096
        _ = ext4_bridge_statfs(ctx, &totalBytes, &freeBytes, &bsize)

        stat.blockSize = Int(bsize)
        stat.ioSize = Int(bsize * 16)
        stat.totalBytes = totalBytes
        stat.freeBytes = freeBytes
        stat.availableBytes = freeBytes
        if bsize > 0 {
            stat.totalBlocks = totalBytes / UInt64(bsize)
            stat.freeBlocks = freeBytes / UInt64(bsize)
            stat.availableBlocks = freeBytes / UInt64(bsize)
        }
        return stat
    }

    public func mount(options: FSTaskOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        if ext4Ctx != nil {
            reply(nil)
        } else if let resource = blockResource {
            let rc = mountViaResource(resource)
            if rc == 0 {
                reply(nil)
            } else {
                reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "Failed to mount ext4 resource"]))
            }
        } else {
            var ctx: OpaquePointer?
            let rc = ext4_bridge_mount(rawDevicePath, isReadOnly ? 1 : 0, &ctx)
            if rc == 0 {
                self.ext4Ctx = ctx
                reply(nil)
            } else {
                reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "Failed to mount ext4 device"]))
            }
        }
    }

    public func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        if let ctx = ext4Ctx {
            ext4_bridge_unmount(ctx)
            ext4Ctx = nil
        }
        ioBridge = nil
        reply()
    }

    public func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        guard let ctx = ext4Ctx else {
            reply(nil)
            return
        }
        let rc = ext4_bridge_sync(ctx)
        if rc == 0 {
            reply(nil)
        } else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        }
    }

    public func reclaimItem(_ item: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: - FSVolumePathConfOperations
    public var maximumLinkCount: Int { 65000 }
    public var maximumNameLength: Int { 255 }
    public var restrictsOwnershipChanges: Bool { true }
    public var truncatesLongNames: Bool { false }

    // MARK: - FSVolumeOperations
    public func activate(options: FSTaskOptions, replyHandler reply: @escaping @Sendable (FSItem?, (any Error)?) -> Void) {
        let rootItem = Ext4FSItem(inodeNumber: 2, itemType: 2) // EXT2_ROOT_INO = 2
        reply(rootItem, nil)
    }

    public func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    public func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let ctx = ext4Ctx else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }

        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? 2
        guard let nameStr = name.string, !nameStr.isEmpty else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }

        var foundIno: UInt64 = 0
        let rc = nameStr.withCString { cName in
            ext4_bridge_lookup(ctx, dirIno, cName, &foundIno)
        }

        if rc == 0 {
            let childItem = Ext4FSItem(inodeNumber: foundIno)
            reply(childItem, name, nil)
        } else if rc == -ENOENT {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
        } else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        }
    }

    public func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }

        guard !isReadOnly else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }

        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? 2
        guard let nameStr = name.string else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }

        var outIno: UInt64 = 0
        let rc: Int32
        if type == .directory {
            rc = nameStr.withCString { cName in
                ext4_bridge_mkdir(ctx, dirIno, cName, 0o755, &outIno)
            }
        } else {
            rc = nameStr.withCString { cName in
                ext4_bridge_create(ctx, dirIno, cName, 0o644, &outIno)
            }
        }

        if rc == 0 {
            let item = Ext4FSItem(inodeNumber: outIno, itemType: type == .directory ? 2 : 1)
            reply(item, name, nil)
        } else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }

        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? 2
        guard let nameStr = name.string, !nameStr.isEmpty, let targetStr = contents.string else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }

        var outIno: UInt64 = 0
        let rc = nameStr.withCString { cName in
            targetStr.withCString { cTarget in
                ext4_bridge_symlink(ctx, dirIno, cName, cTarget, &outIno)
            }
        }

        if rc == 0 {
            let item = Ext4FSItem(inodeNumber: outIno, itemType: 3)
            reply(item, name, nil)
        } else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }

        guard let targetIno = (item as? Ext4FSItem)?.inodeNumber,
              let nameStr = name.string, !nameStr.isEmpty else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? 2

        let rc = nameStr.withCString { cName in
            ext4_bridge_link(ctx, targetIno, dirIno, cName)
        }
        reply(rc == 0 ? name : nil, rc == 0 ? nil : NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
    }

    public func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }

        let oldDirIno = (sourceDirectory as? Ext4FSItem)?.inodeNumber ?? 2
        let newDirIno = (destinationDirectory as? Ext4FSItem)?.inodeNumber ?? 2
        guard let oldName = sourceName.string, !oldName.isEmpty,
              let newName = destinationName.string, !newName.isEmpty else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }

        let rc = oldName.withCString { cOld in
            newName.withCString { cNew in
                ext4_bridge_rename(ctx, oldDirIno, cOld, newDirIno, cNew)
            }
        }
        reply(rc == 0 ? destinationName : nil, rc == 0 ? nil : NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
    }

    public func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }

        guard !isReadOnly else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }

        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? 2
        guard let nameStr = name.string else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }

        let rc = nameStr.withCString { cName in
            ext4_bridge_unlink(ctx, dirIno, cName)
        }
        reply(rc == 0 ? nil : NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
    }

    public func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }

        let ino = (item as? Ext4FSItem)?.inodeNumber ?? 2
        var cAttrs = ext4_item_attrs_t()
        let rc = ext4_bridge_get_attrs(ctx, ino, &cAttrs)
        if rc != 0 {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            return
        }

        let attrs = FSItem.Attributes()
        attrs.fileID = FSItem.Identifier(rawValue: cAttrs.ino) ?? .invalid
        attrs.uid = cAttrs.uid
        attrs.gid = cAttrs.gid
        attrs.mode = cAttrs.mode
        attrs.size = cAttrs.size
        attrs.allocSize = cAttrs.alloc_size
        attrs.linkCount = cAttrs.link_count
        attrs.flags = cAttrs.flags
        attrs.accessTime = timespec(tv_sec: Int(cAttrs.atime_sec), tv_nsec: Int(cAttrs.atime_nsec))
        attrs.modifyTime = timespec(tv_sec: Int(cAttrs.mtime_sec), tv_nsec: Int(cAttrs.mtime_nsec))
        attrs.changeTime = timespec(tv_sec: Int(cAttrs.ctime_sec), tv_nsec: Int(cAttrs.ctime_nsec))
        attrs.birthTime = timespec(tv_sec: Int(cAttrs.btime_sec), tv_nsec: Int(cAttrs.btime_nsec))

        switch cAttrs.file_type {
        case 1: attrs.type = .file
        case 2: attrs.type = .directory
        case 3: attrs.type = .symlink
        default: attrs.type = .unknown
        }

        reply(attrs, nil)
    }

    public func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }

        let ino = (item as? Ext4FSItem)?.inodeNumber ?? 2
        var cAttrs = ext4_item_attrs_t()
        var mask: UInt32 = 0
        var consumed: FSItem.Attribute = []

        if newAttributes.isValid(.mode) {
            cAttrs.mode = newAttributes.mode
            mask |= 0x01
            consumed.insert(.mode)
        }
        if newAttributes.isValid(.uid) {
            cAttrs.uid = newAttributes.uid
            mask |= 0x02
            consumed.insert(.uid)
        }
        if newAttributes.isValid(.gid) {
            cAttrs.gid = newAttributes.gid
            mask |= 0x04
            consumed.insert(.gid)
        }
        if newAttributes.isValid(.modifyTime) {
            cAttrs.mtime_sec = UInt64(max(0, newAttributes.modifyTime.tv_sec))
            cAttrs.mtime_nsec = UInt32(max(0, newAttributes.modifyTime.tv_nsec))
            mask |= 0x08
            consumed.insert(.modifyTime)
        }
        if newAttributes.isValid(.accessTime) {
            cAttrs.atime_sec = UInt64(max(0, newAttributes.accessTime.tv_sec))
            cAttrs.atime_nsec = UInt32(max(0, newAttributes.accessTime.tv_nsec))
            mask |= 0x10
            consumed.insert(.accessTime)
        }
        if newAttributes.isValid(.size) {
            cAttrs.size = newAttributes.size
            mask |= 0x20
            consumed.insert(.size)
        }

        if mask != 0 {
            let rc = ext4_bridge_set_attrs(ctx, ino, mask, &cAttrs)
            if rc != 0 {
                reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
                return
            }
            newAttributes.consumedAttributes = consumed
        }

        getAttributes(FSItem.GetAttributesRequest(), of: item, replyHandler: reply)
    }

    public func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping @Sendable (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(verifier, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }

        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? 2

        _ = ext4_bridge_readdir(ctx, dirIno, cookie.rawValue, { userCtx, cName, ino, fType, nextCookie in
            guard let userCtx = userCtx, let cName = cName else { return Int32(0) }
            let unmanagedPacker = Unmanaged<FSDirectoryEntryPacker>.fromOpaque(userCtx).takeUnretainedValue()
            let nameStr = String(cString: cName)
            let fn = FSFileName(string: nameStr)
            let itemType: FSItem.ItemType
            switch fType {
            case 1: itemType = .file
            case 2: itemType = .directory
            case 3: itemType = .symlink
            default: itemType = .unknown
            }
            let itemID = FSItem.Identifier(rawValue: ino) ?? .invalid
            let success = unmanagedPacker.packEntry(
                name: fn,
                itemType: itemType,
                itemID: itemID,
                nextCookie: FSDirectoryCookie(rawValue: nextCookie),
                attributes: nil
            )
            return success ? Int32(1) : Int32(0)
        }, Unmanaged.passUnretained(packer).toOpaque())

        reply(FSDirectoryVerifier(rawValue: verifier.rawValue + 1), nil)
    }

    public func readSymbolicLink(
        _ item: FSItem,
        replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }

        let ino = (item as? Ext4FSItem)?.inodeNumber ?? 2
        var buf = [CChar](repeating: 0, count: 4096)
        var outLen: Int = 0
        let rc = ext4_bridge_readlink(ctx, ino, &buf, buf.count, &outLen)
        if rc == 0 {
            let target = buf.withUnsafeBufferPointer { ptr in
                String(cString: ptr.baseAddress!)
            }
            reply(FSFileName(string: target), nil)
        } else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        }
    }

    // MARK: - FSVolumeReadWriteOperations
    public func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }

        let ino = (item as? Ext4FSItem)?.inodeNumber ?? 2
        var actuallyRead: Int = 0
        var readErr: Int32 = 0

        buffer.withUnsafeMutableBytes { rawBuf in
            guard let baseAddr = rawBuf.baseAddress else {
                readErr = -EINVAL
                return
            }
            var got: Int = 0
            let rc = ext4_bridge_read(ctx, ino, UInt64(offset), length, baseAddr, &got)
            if rc == 0 {
                actuallyRead = got
            } else {
                readErr = rc
            }
        }

        if readErr == 0 {
            reply(actuallyRead, nil)
        } else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(-readErr)))
        }
    }

    public func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void
    ) {
        guard let ctx = ext4Ctx else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }

        guard !isReadOnly else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }

        let ino = (item as? Ext4FSItem)?.inodeNumber ?? 2
        var written: Int = 0

        let rc = contents.withUnsafeBytes { rawBuf in
            guard let baseAddr = rawBuf.baseAddress else { return Int32(-EINVAL) }
            var outWritten: Int = 0
            let r = ext4_bridge_write(ctx, ino, UInt64(offset), contents.count, baseAddr, &outWritten)
            written = outWritten
            return r
        }

        if rc == 0 {
            reply(written, nil)
        } else {
            reply(written, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }
}

/// Read-only FSKit Volume backed by CLegacyFS (ReiserFS, UFS/UFS2, JFS, SquashFS, EROFS, ISO9660, CramFS, ROMFS, Minix, SysV)
@available(macOS 15.4, *)
public final class LegacyFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, @unchecked Sendable {
    private var lfsHandle: OpaquePointer?
    private var ioBridge: FSBlockDeviceIOBridge?
    public let blockResource: FSBlockDeviceResource?
    public let rawDevicePath: String

    public init(volumeID: FSVolume.Identifier, volumeName: FSFileName, resource: FSBlockDeviceResource) {
        self.blockResource = resource
        self.rawDevicePath = "/dev/\(resource.bsdName)"
        super.init(volumeID: volumeID, volumeName: volumeName)
        _ = openViaResource(resource)
    }

    private func openViaResource(_ resource: FSBlockDeviceResource) -> Int32 {
        let bridge = FSBlockDeviceIOBridge(resource: resource)
        let ctxPtr = Unmanaged.passUnretained(bridge).toOpaque()

        let readFn: legacyfs_read_fn = { rawCtx, offset, length, buffer in
            guard let rawCtx, let buffer else { return EINVAL }
            if length == 0 { return 0 }
            let box = Unmanaged<FSBlockDeviceIOBridge>.fromOpaque(rawCtx).takeUnretainedValue()
            guard let data = box.readBytes(offset: offset, length: length), data.count == length else {
                return EIO
            }
            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: length)
            return 0
        }

        var handle: OpaquePointer?
        let rc = legacyfs_open_io(readFn, ctxPtr, 0, LEGACYFS_KIND_UNKNOWN, &handle)
        if rc == 0 {
            self.ioBridge = bridge
            self.lfsHandle = handle
        }
        return rc
    }

    deinit {
        if let h = lfsHandle {
            legacyfs_close(h)
            lfsHandle = nil
        }
        ioBridge = nil
    }

    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = true
        return caps
    }

    public var volumeStatistics: FSStatFSResult {
        let stat = FSStatFSResult(fileSystemTypeName: "legacyfs")
        guard let h = lfsHandle else {
            stat.blockSize = 4096
            stat.ioSize = 65536
            return stat
        }
        var cStat = legacyfs_statfs_t()
        _ = legacyfs_statfs(h, &cStat)
        let bsize = max(Int(cStat.block_size), 512)
        stat.blockSize = bsize
        stat.ioSize = max(bsize * 16, 65536)
        stat.totalBlocks = cStat.total_blocks
        stat.freeBlocks = 0
        stat.availableBlocks = 0
        stat.totalBytes = cStat.total_blocks * UInt64(bsize)
        stat.freeBytes = 0
        stat.availableBytes = 0
        return stat
    }

    public func mount(options: FSTaskOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        if lfsHandle != nil {
            reply(nil)
        } else if let resource = blockResource, openViaResource(resource) == 0 {
            reply(nil)
        } else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        }
    }

    public func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        if let h = lfsHandle {
            legacyfs_close(h)
            lfsHandle = nil
        }
        ioBridge = nil
        reply()
    }

    public func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    public func reclaimItem(_ item: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    public var maximumLinkCount: Int { 65000 }
    public var maximumNameLength: Int { 255 }
    public var restrictsOwnershipChanges: Bool { true }
    public var truncatesLongNames: Bool { false }

    public func activate(options: FSTaskOptions, replyHandler reply: @escaping @Sendable (FSItem?, (any Error)?) -> Void) {
        let rootIno = lfsHandle.map { legacyfs_root_ino($0) } ?? 1
        reply(Ext4FSItem(inodeNumber: rootIno, itemType: 2), nil)
    }

    public func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    public func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let h = lfsHandle, let nameStr = name.string, !nameStr.isEmpty else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? legacyfs_root_ino(h)
        var foundIno: UInt64 = 0
        let rc = nameStr.withCString { cName in
            legacyfs_lookup(h, dirIno, cName, &foundIno)
        }
        if rc == 0 {
            reply(Ext4FSItem(inodeNumber: foundIno), name, nil)
        } else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }

    public func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }

    public func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }

    public func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }

    public func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }

    public func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let h = lfsHandle else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? legacyfs_root_ino(h)
        var cAttr = legacyfs_attr_t()
        let rc = legacyfs_getattr(h, ino, &cAttr)
        guard rc == 0 else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
            return
        }

        let attrs = FSItem.Attributes()
        attrs.fileID = FSItem.Identifier(rawValue: cAttr.ino) ?? .invalid
        attrs.uid = cAttr.uid
        attrs.gid = cAttr.gid
        attrs.mode = cAttr.mode & ~UInt32(0o222)
        attrs.size = cAttr.size
        attrs.allocSize = cAttr.blocks_512 * 512
        attrs.linkCount = max(cAttr.nlink, 1)
        attrs.accessTime = timespec(tv_sec: Int(cAttr.atime_sec), tv_nsec: 0)
        attrs.modifyTime = timespec(tv_sec: Int(cAttr.mtime_sec), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(cAttr.ctime_sec), tv_nsec: 0)
        switch cAttr.ftype {
        case LEGACYFS_FT_REG: attrs.type = .file
        case LEGACYFS_FT_DIR: attrs.type = .directory
        case LEGACYFS_FT_SYMLINK: attrs.type = .symlink
        default: attrs.type = .unknown
        }
        reply(attrs, nil)
    }

    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void) {
        reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }

    private final class LegacyDirPackContext {
        let packer: FSDirectoryEntryPacker
        let skipCount: UInt64
        var index: UInt64 = 0
        init(packer: FSDirectoryEntryPacker, skipCount: UInt64) {
            self.packer = packer
            self.skipCount = skipCount
        }
    }

    public func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping @Sendable (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let h = lfsHandle else {
            reply(verifier, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? legacyfs_root_ino(h)
        let packCtx = LegacyDirPackContext(packer: packer, skipCount: cookie.rawValue)

        _ = legacyfs_readdir(h, dirIno, { rawCtx, cName, ino, ftype in
            guard let rawCtx, let cName else { return 0 }
            let ctx = Unmanaged<LegacyDirPackContext>.fromOpaque(rawCtx).takeUnretainedValue()
            let currentIdx = ctx.index
            ctx.index += 1
            if currentIdx < ctx.skipCount {
                return 0
            }
            let itemType: FSItem.ItemType
            switch ftype {
            case LEGACYFS_FT_REG: itemType = .file
            case LEGACYFS_FT_DIR: itemType = .directory
            case LEGACYFS_FT_SYMLINK: itemType = .symlink
            default: itemType = .unknown
            }
            let ok = ctx.packer.packEntry(
                name: FSFileName(string: String(cString: cName)),
                itemType: itemType,
                itemID: FSItem.Identifier(rawValue: ino) ?? .invalid,
                nextCookie: FSDirectoryCookie(rawValue: currentIdx + 1),
                attributes: nil
            )
            return ok ? 0 : 1
        }, Unmanaged.passUnretained(packCtx).toOpaque())

        reply(FSDirectoryVerifier(rawValue: verifier.rawValue + 1), nil)
    }

    public func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        guard let h = lfsHandle else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? legacyfs_root_ino(h)
        var buf = [CChar](repeating: 0, count: 4096)
        var outLen: Int = 0
        let rc = legacyfs_readlink(h, ino, &buf, buf.count, &outLen)
        if rc == 0 {
            let target = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            reply(FSFileName(string: target), nil)
        } else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void) {
        guard let h = lfsHandle else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? legacyfs_root_ino(h)
        var actuallyRead = 0
        var readErr: Int32 = 0
        buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else {
                readErr = -EINVAL
                return
            }
            var got = 0
            let rc = legacyfs_read(h, ino, UInt64(max(offset, 0)), length, base, &got)
            if rc == 0 {
                actuallyRead = got
            } else {
                readErr = rc
            }
        }
        if readErr == 0 {
            reply(actuallyRead, nil)
        } else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(-readErr)))
        }
    }

    public func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void) {
        reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }
}

/// Read-only FSKit Volume backed by CAppleExplorer (Classic HFS, HFS+ Backups.backupdb, and APFS Snapshots)
@available(macOS 15.4, *)
public final class AppleExplorerFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, @unchecked Sendable {
    private var aexHandle: OpaquePointer?
    private var ioBridge: FSBlockDeviceIOBridge?
    public let blockResource: FSBlockDeviceResource?
    public let rawDevicePath: String

    public init(volumeID: FSVolume.Identifier, volumeName: FSFileName, resource: FSBlockDeviceResource) {
        self.blockResource = resource
        self.rawDevicePath = "/dev/\(resource.bsdName)"
        super.init(volumeID: volumeID, volumeName: volumeName)
        _ = openViaResource(resource)
    }

    private func openViaResource(_ resource: FSBlockDeviceResource) -> Int32 {
        let bridge = FSBlockDeviceIOBridge(resource: resource)
        let ctxPtr = Unmanaged.passUnretained(bridge).toOpaque()
        let totalBytes = UInt64(max(resource.blockCount, 0)) * UInt64(max(resource.blockSize, 512))

        let readFn: aex_read_fn = { rawCtx, offset, length, buffer in
            guard let rawCtx, let buffer else { return Int32(-EINVAL) }
            if length == 0 { return 0 }
            let box = Unmanaged<FSBlockDeviceIOBridge>.fromOpaque(rawCtx).takeUnretainedValue()
            guard let data = box.readBytes(offset: offset, length: length), data.count == length else {
                return Int32(-EIO)
            }
            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: length)
            return 0
        }

        var handle: OpaquePointer?
        var opts = aex_open_options_t(partition_index: -1, volume_index: -1, snapshot_name: nil, password: nil)
        let rc = aex_open_io(readFn, ctxPtr, totalBytes, &opts, &handle)
        if rc == 0 {
            self.ioBridge = bridge
            self.aexHandle = handle
        }
        return rc
    }

    deinit {
        if let h = aexHandle {
            aex_close(h)
            aexHandle = nil
        }
        ioBridge = nil
    }

    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = true
        return caps
    }

    public var volumeStatistics: FSStatFSResult {
        let stat = FSStatFSResult(fileSystemTypeName: "apple-explorer")
        guard let h = aexHandle else {
            stat.blockSize = 4096
            stat.ioSize = 65536
            return stat
        }
        var totalBytes: UInt64 = 0
        var usedBytes: UInt64 = 0
        var blockSz: UInt32 = 4096
        _ = aex_statfs(h, &totalBytes, &usedBytes, &blockSz)
        let bsize = max(Int(blockSz), 512)
        stat.blockSize = bsize
        stat.ioSize = max(bsize * 16, 65536)
        stat.totalBlocks = totalBytes / UInt64(bsize)
        stat.freeBlocks = 0
        stat.availableBlocks = 0
        stat.totalBytes = totalBytes
        stat.freeBytes = 0
        stat.availableBytes = 0
        return stat
    }

    public func mount(options: FSTaskOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        if aexHandle != nil {
            reply(nil)
        } else if let resource = blockResource, openViaResource(resource) == 0 {
            reply(nil)
        } else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        }
    }

    public func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        if let h = aexHandle {
            aex_close(h)
            aexHandle = nil
        }
        ioBridge = nil
        reply()
    }

    public func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    public func reclaimItem(_ item: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }
    public var maximumLinkCount: Int { 65000 }
    public var maximumNameLength: Int { 255 }
    public var restrictsOwnershipChanges: Bool { true }
    public var truncatesLongNames: Bool { false }

    public func activate(options: FSTaskOptions, replyHandler reply: @escaping @Sendable (FSItem?, (any Error)?) -> Void) {
        let rootIno = aexHandle.map { aex_root_ino($0) } ?? 2
        reply(Ext4FSItem(inodeNumber: rootIno, itemType: 2), nil)
    }

    public func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) { reply(nil) }

    public func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let h = aexHandle, let nameStr = name.string, !nameStr.isEmpty else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? aex_root_ino(h)
        var foundIno: UInt64 = 0
        let rc = nameStr.withCString { cName in
            aex_lookup(h, dirIno, cName, &foundIno)
        }
        if rc == 0 {
            reply(Ext4FSItem(inodeNumber: foundIno), name, nil)
        } else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }
    public func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }
    public func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }
    public func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }
    public func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }

    public func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let h = aexHandle else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? aex_root_ino(h)
        var cAttr = aex_attr_t()
        let rc = aex_getattr(h, ino, &cAttr)
        guard rc == 0 else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
            return
        }
        let attrs = FSItem.Attributes()
        attrs.fileID = FSItem.Identifier(rawValue: cAttr.ino) ?? .invalid
        attrs.uid = cAttr.uid
        attrs.gid = cAttr.gid
        attrs.mode = cAttr.mode & ~UInt32(0o222)
        attrs.size = cAttr.size
        attrs.allocSize = ((cAttr.size + 4095) / 4096) * 4096
        attrs.linkCount = max(cAttr.nlink, 1)
        attrs.accessTime = timespec(tv_sec: Int(cAttr.atime_sec), tv_nsec: 0)
        attrs.modifyTime = timespec(tv_sec: Int(cAttr.mtime_sec), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(cAttr.ctime_sec), tv_nsec: 0)
        switch cAttr.ftype {
        case AEX_FT_REG: attrs.type = .file
        case AEX_FT_DIR: attrs.type = .directory
        case AEX_FT_SYMLINK: attrs.type = .symlink
        default: attrs.type = .unknown
        }
        reply(attrs, nil)
    }

    public func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void) {
        reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }

    private final class AEXDirPackContext {
        let packer: FSDirectoryEntryPacker
        let skipCount: UInt64
        var index: UInt64 = 0
        init(packer: FSDirectoryEntryPacker, skipCount: UInt64) {
            self.packer = packer
            self.skipCount = skipCount
        }
    }

    public func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping @Sendable (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let h = aexHandle else {
            reply(verifier, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? aex_root_ino(h)
        let packCtx = AEXDirPackContext(packer: packer, skipCount: cookie.rawValue)

        _ = aex_readdir(h, dirIno, { rawCtx, cName, ino, ftype in
            guard let rawCtx, let cName else { return 0 }
            let ctx = Unmanaged<AEXDirPackContext>.fromOpaque(rawCtx).takeUnretainedValue()
            let currentIdx = ctx.index
            ctx.index += 1
            if currentIdx < ctx.skipCount { return 0 }
            let itemType: FSItem.ItemType
            switch ftype {
            case AEX_FT_REG: itemType = .file
            case AEX_FT_DIR: itemType = .directory
            case AEX_FT_SYMLINK: itemType = .symlink
            default: itemType = .unknown
            }
            let ok = ctx.packer.packEntry(
                name: FSFileName(string: String(cString: cName)),
                itemType: itemType,
                itemID: FSItem.Identifier(rawValue: ino) ?? .invalid,
                nextCookie: FSDirectoryCookie(rawValue: currentIdx + 1),
                attributes: nil
            )
            return ok ? 0 : 1
        }, Unmanaged.passUnretained(packCtx).toOpaque())

        reply(FSDirectoryVerifier(rawValue: verifier.rawValue + 1), nil)
    }

    public func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        guard let h = aexHandle else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? aex_root_ino(h)
        var buf = [CChar](repeating: 0, count: 4096)
        var outLen = 0
        let rc = aex_readlink(h, ino, &buf, buf.count, &outLen)
        if rc == 0 {
            let target = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            reply(FSFileName(string: target), nil)
        } else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void) {
        guard let h = aexHandle else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? aex_root_ino(h)
        var actuallyRead = 0
        var readErr: Int32 = 0
        buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { readErr = -EINVAL; return }
            var got = 0
            let rc = aex_read(h, ino, UInt64(max(offset, 0)), length, base, &got)
            if rc == 0 { actuallyRead = got } else { readErr = rc }
        }
        if readErr == 0 {
            reply(actuallyRead, nil)
        } else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(-readErr)))
        }
    }

    public func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void) {
        reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
    }
}

/// Read-write FSKit Volume backed by CCowFS (XFS v4/v5 and Btrfs Copy-on-Write)
@available(macOS 15.4, *)
public final class CowFSKitVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, @unchecked Sendable {
    private var cowHandle: OpaquePointer?
    private var ioBridge: FSBlockDeviceIOBridge?
    public let kind: cowfs_kind_t
    public let blockResource: FSBlockDeviceResource?
    public let rawDevicePath: String
    public let isReadOnly: Bool

    public init(volumeID: FSVolume.Identifier, volumeName: FSFileName, kind: cowfs_kind_t, devicePath: String, readOnly: Bool = false) {
        self.kind = kind
        self.blockResource = nil
        self.rawDevicePath = devicePath
        self.isReadOnly = readOnly
        super.init(volumeID: volumeID, volumeName: volumeName)

        var handle: OpaquePointer?
        if cowfs_mount_path(kind, devicePath, readOnly ? 1 : 0, &handle) == 0 {
            self.cowHandle = handle
        }
    }

    public init(volumeID: FSVolume.Identifier, volumeName: FSFileName, kind: cowfs_kind_t, resource: FSBlockDeviceResource, readOnly: Bool = false) {
        self.kind = kind
        self.blockResource = resource
        self.rawDevicePath = "/dev/\(resource.bsdName)"
        self.isReadOnly = readOnly || !resource.isWritable
        super.init(volumeID: volumeID, volumeName: volumeName)
        _ = mountViaResource(resource)
    }

    private func mountViaResource(_ resource: FSBlockDeviceResource) -> Int32 {
        let bridge = FSBlockDeviceIOBridge(resource: resource)
        let ctxPtr = Unmanaged.passUnretained(bridge).toOpaque()
        let totalBytes = UInt64(max(resource.blockCount, 0)) * UInt64(max(resource.blockSize, 512))

        let readFn: cowfs_io_read_fn = { rawCtx, offset, length, buffer in
            guard let rawCtx, let buffer else { return Int32(-EINVAL) }
            if length == 0 { return 0 }
            let box = Unmanaged<FSBlockDeviceIOBridge>.fromOpaque(rawCtx).takeUnretainedValue()
            guard let data = box.readBytes(offset: offset, length: length), data.count == length else {
                return Int32(-EIO)
            }
            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: length)
            return 0
        }

        let writeFn: cowfs_io_write_fn = { rawCtx, offset, length, buffer in
            guard let rawCtx, let buffer else { return Int32(-EINVAL) }
            let box = Unmanaged<FSBlockDeviceIOBridge>.fromOpaque(rawCtx).takeUnretainedValue()
            return box.writeBytes(offset: offset, buffer: buffer, length: length)
        }

        let flushFn: cowfs_io_flush_fn = { rawCtx in
            guard let rawCtx else { return 0 }
            let box = Unmanaged<FSBlockDeviceIOBridge>.fromOpaque(rawCtx).takeUnretainedValue()
            do {
                try box.resource.metadataFlush()
                return 0
            } catch {
                return Int32(-EIO)
            }
        }

        var handle: OpaquePointer?
        let rc = cowfs_mount_io(
            kind,
            totalBytes,
            isReadOnly ? 1 : 0,
            ctxPtr,
            readFn,
            isReadOnly ? nil : writeFn,
            flushFn,
            &handle
        )
        if rc == 0 {
            self.ioBridge = bridge
            self.cowHandle = handle
        }
        return rc
    }

    deinit {
        if let h = cowHandle {
            cowfs_unmount(h)
            cowHandle = nil
        }
        ioBridge = nil
    }

    public var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.supportsJournal = true
        caps.supportsActiveJournal = true
        return caps
    }

    public var volumeStatistics: FSStatFSResult {
        let fsName = (kind == COWFS_KIND_XFS) ? "xfs" : "btrfs"
        let stat = FSStatFSResult(fileSystemTypeName: fsName)
        guard let h = cowHandle else {
            stat.blockSize = 4096
            stat.ioSize = 65536
            return stat
        }
        var totalBytes: UInt64 = 0
        var freeBytes: UInt64 = 0
        var bsize: UInt32 = 4096
        _ = cowfs_statfs(h, &totalBytes, &freeBytes, &bsize)
        let bs = max(Int(bsize), 512)
        stat.blockSize = bs
        stat.ioSize = max(bs * 16, 65536)
        stat.totalBytes = totalBytes
        stat.freeBytes = freeBytes
        stat.availableBytes = freeBytes
        stat.totalBlocks = totalBytes / UInt64(bs)
        stat.freeBlocks = freeBytes / UInt64(bs)
        stat.availableBlocks = freeBytes / UInt64(bs)
        return stat
    }

    public func mount(options: FSTaskOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        if cowHandle != nil {
            reply(nil)
        } else if let resource = blockResource, mountViaResource(resource) == 0 {
            reply(nil)
        } else {
            var handle: OpaquePointer?
            let rc = cowfs_mount_path(kind, rawDevicePath, isReadOnly ? 1 : 0, &handle)
            if rc == 0 {
                self.cowHandle = handle
                reply(nil)
            } else {
                reply(NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
            }
        }
    }

    public func unmount(replyHandler reply: @escaping @Sendable () -> Void) {
        if let h = cowHandle {
            cowfs_unmount(h)
            cowHandle = nil
        }
        ioBridge = nil
        reply()
    }

    public func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        guard let h = cowHandle else {
            reply(nil)
            return
        }
        let rc = cowfs_sync(h)
        reply(rc == 0 ? nil : NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
    }

    public func reclaimItem(_ item: FSItem, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    public var maximumLinkCount: Int { 65000 }
    public var maximumNameLength: Int { 255 }
    public var restrictsOwnershipChanges: Bool { true }
    public var truncatesLongNames: Bool { false }

    public func activate(options: FSTaskOptions, replyHandler reply: @escaping @Sendable (FSItem?, (any Error)?) -> Void) {
        let rootIno = cowHandle.map { cowfs_root_ino($0) } ?? 256
        reply(Ext4FSItem(inodeNumber: rootIno, itemType: 2), nil)
    }

    public func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping @Sendable ((any Error)?) -> Void) {
        reply(nil)
    }

    public func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let h = cowHandle, let nameStr = name.string, !nameStr.isEmpty else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        var foundIno: UInt64 = 0
        let rc = nameStr.withCString { cowfs_lookup(h, dirIno, $0, &foundIno) }
        if rc == 0 {
            reply(Ext4FSItem(inodeNumber: foundIno), name, nil)
        } else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let h = cowHandle else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }
        guard let nameStr = name.string, !nameStr.isEmpty else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        var outIno: UInt64 = 0
        let rc: Int32
        if type == .directory {
            let mode = newAttributes.isValid(.mode) ? newAttributes.mode : 0o755
            rc = nameStr.withCString { cowfs_mkdir(h, dirIno, $0, mode, &outIno) }
        } else {
            let mode = newAttributes.isValid(.mode) ? newAttributes.mode : 0o644
            rc = nameStr.withCString { cowfs_create(h, dirIno, $0, mode, &outIno) }
        }
        if rc == 0 {
            reply(Ext4FSItem(inodeNumber: outIno, itemType: type == .directory ? 2 : 1), name, nil)
        } else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes newAttributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler reply: @escaping @Sendable (FSItem?, FSFileName?, (any Error)?) -> Void
    ) {
        guard let h = cowHandle else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }
        guard let nameStr = name.string, !nameStr.isEmpty, let targetStr = contents.string else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        var outIno: UInt64 = 0
        let rc = nameStr.withCString { cName in
            targetStr.withCString { cTarget in
                cowfs_symlink(h, dirIno, cName, cTarget, &outIno)
            }
        }
        if rc == 0 {
            reply(Ext4FSItem(inodeNumber: outIno, itemType: 3), name, nil)
        } else {
            reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))
    }

    public func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void
    ) {
        guard let h = cowHandle else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }
        guard let oldName = sourceName.string, !oldName.isEmpty,
              let newName = destinationName.string, !newName.isEmpty else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        let oldDir = (sourceDirectory as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        let newDir = (destinationDirectory as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        let rc = oldName.withCString { cOld in
            newName.withCString { cNew in
                cowfs_rename(h, oldDir, cOld, newDir, cNew)
            }
        }
        reply(rc == 0 ? destinationName : nil, rc == 0 ? nil : NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
    }

    public func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        guard let h = cowHandle else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }
        guard let nameStr = name.string, !nameStr.isEmpty else {
            reply(NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        var isDir = ((item as? Ext4FSItem)?.itemType == 2)
        if !isDir, let itemIno = (item as? Ext4FSItem)?.inodeNumber {
            var cAttrs = cowfs_item_attrs_t()
            if cowfs_getattr(h, itemIno, &cAttrs) == 0 && cAttrs.file_type == 2 {
                isDir = true
            }
        }
        let rc = nameStr.withCString { cName in
            isDir ? cowfs_rmdir(h, dirIno, cName) : cowfs_unlink(h, dirIno, cName)
        }
        reply(rc == 0 ? nil : NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
    }

    public func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let h = cowHandle else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        var cAttrs = cowfs_item_attrs_t()
        let rc = cowfs_getattr(h, ino, &cAttrs)
        guard rc == 0 else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
            return
        }

        let attrs = FSItem.Attributes()
        attrs.fileID = FSItem.Identifier(rawValue: cAttrs.ino) ?? .invalid
        attrs.uid = cAttrs.uid
        attrs.gid = cAttrs.gid
        attrs.mode = isReadOnly ? (cAttrs.mode & ~UInt32(0o222)) : cAttrs.mode
        attrs.size = cAttrs.size
        attrs.allocSize = cAttrs.alloc_size
        attrs.linkCount = max(cAttrs.nlink, 1)
        attrs.accessTime = timespec(tv_sec: Int(cAttrs.atime_sec), tv_nsec: 0)
        attrs.modifyTime = timespec(tv_sec: Int(cAttrs.mtime_sec), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(cAttrs.ctime_sec), tv_nsec: 0)
        switch cAttrs.file_type {
        case 1: attrs.type = .file
        case 2: attrs.type = .directory
        case 3: attrs.type = .symlink
        default: attrs.type = .unknown
        }
        reply(attrs, nil)
    }

    public func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping @Sendable (FSItem.Attributes?, (any Error)?) -> Void
    ) {
        guard let h = cowHandle else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        var cAttrs = cowfs_item_attrs_t()
        var mask: UInt32 = 0
        var consumed: FSItem.Attribute = []

        if newAttributes.isValid(.mode) {
            cAttrs.mode = newAttributes.mode
            mask |= UInt32(COWFS_ATTR_MODE)
            consumed.insert(.mode)
        }
        if newAttributes.isValid(.uid) {
            cAttrs.uid = newAttributes.uid
            mask |= UInt32(COWFS_ATTR_UID)
            consumed.insert(.uid)
        }
        if newAttributes.isValid(.gid) {
            cAttrs.gid = newAttributes.gid
            mask |= UInt32(COWFS_ATTR_GID)
            consumed.insert(.gid)
        }
        if newAttributes.isValid(.modifyTime) {
            cAttrs.mtime_sec = Int64(newAttributes.modifyTime.tv_sec)
            mask |= UInt32(COWFS_ATTR_MTIME)
            consumed.insert(.modifyTime)
        }
        if newAttributes.isValid(.accessTime) {
            cAttrs.atime_sec = Int64(newAttributes.accessTime.tv_sec)
            mask |= UInt32(COWFS_ATTR_ATIME)
            consumed.insert(.accessTime)
        }
        if newAttributes.isValid(.size) {
            cAttrs.size = newAttributes.size
            mask |= UInt32(COWFS_ATTR_SIZE)
            consumed.insert(.size)
        }

        if mask != 0 {
            let rc = cowfs_setattr(h, ino, mask, &cAttrs)
            if rc != 0 {
                reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
                return
            }
            newAttributes.consumedAttributes = consumed
        }
        getAttributes(FSItem.GetAttributesRequest(), of: item, replyHandler: reply)
    }

    public func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping @Sendable (FSDirectoryVerifier, (any Error)?) -> Void
    ) {
        guard let h = cowHandle else {
            reply(verifier, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let dirIno = (directory as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        _ = cowfs_readdir(h, dirIno, cookie.rawValue, { userCtx, cName, ino, fType, nextCookie in
            guard let userCtx, let cName else { return 0 }
            let unmanagedPacker = Unmanaged<FSDirectoryEntryPacker>.fromOpaque(userCtx).takeUnretainedValue()
            let itemType: FSItem.ItemType
            switch fType {
            case 1: itemType = .file
            case 2: itemType = .directory
            case 3: itemType = .symlink
            default: itemType = .unknown
            }
            let ok = unmanagedPacker.packEntry(
                name: FSFileName(string: String(cString: cName)),
                itemType: itemType,
                itemID: FSItem.Identifier(rawValue: ino) ?? .invalid,
                nextCookie: FSDirectoryCookie(rawValue: nextCookie),
                attributes: nil
            )
            return ok ? 0 : 1
        }, Unmanaged.passUnretained(packer).toOpaque())
        reply(FSDirectoryVerifier(rawValue: verifier.rawValue + 1), nil)
    }

    public func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping @Sendable (FSFileName?, (any Error)?) -> Void) {
        guard let h = cowHandle else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        var buf = [CChar](repeating: 0, count: 4096)
        var outLen: Int = 0
        let rc = cowfs_readlink(h, ino, &buf, buf.count, &outLen)
        if rc == 0 {
            let target = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            reply(FSFileName(string: target), nil)
        } else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }

    public func read(
        from item: FSItem,
        at offset: off_t,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void
    ) {
        guard let h = cowHandle else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        var actuallyRead = 0
        var readErr: Int32 = 0
        buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else {
                readErr = -EINVAL
                return
            }
            var got = 0
            let rc = cowfs_read(h, ino, UInt64(max(offset, 0)), length, base, &got)
            if rc == 0 {
                actuallyRead = got
            } else {
                readErr = rc
            }
        }
        if readErr == 0 {
            reply(actuallyRead, nil)
        } else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(-readErr)))
        }
    }

    public func write(
        contents: Data,
        to item: FSItem,
        at offset: off_t,
        replyHandler reply: @escaping @Sendable (Int, (any Error)?) -> Void
    ) {
        guard let h = cowHandle else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
            return
        }
        guard !isReadOnly else {
            reply(0, NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)))
            return
        }
        let ino = (item as? Ext4FSItem)?.inodeNumber ?? cowfs_root_ino(h)
        var written = 0
        let rc = contents.withUnsafeBytes { rawBuf -> Int32 in
            guard let base = rawBuf.baseAddress else { return -EINVAL }
            var outW = 0
            let r = cowfs_write(h, ino, UInt64(max(offset, 0)), contents.count, base, &outW)
            written = outW
            return r
        }
        if rc == 0 {
            reply(written, nil)
        } else {
            reply(written, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
        }
    }
}

/// Native FSKit Unary File System Extension (Read-Write ext2/3/4, XFS, Btrfs, and Read-Only legacyfs formats)
@available(macOS 15.4, *)
public final class Ext4FSUnaryFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    public var activeVolume: Ext4FSVolume?
    public var activeCowVolume: CowFSKitVolume?
    public var activeLegacyVolume: LegacyFSVolume?
    public var activeAppleVolume: AppleExplorerFSVolume?

    public override init() {
        super.init()
    }

    public func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping @Sendable (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let blockResource = resource as? FSBlockDeviceResource else {
            reply(FSProbeResult.notRecognized, nil)
            return
        }

        let reader = FSBlockDeviceIOBridge(resource: blockResource)
        let probeResult = SuperblockProbe.probe(reader: reader) ?? SuperblockProbe.probe(path: "/dev/\(blockResource.bsdName)")
        if let probe = probeResult, probe.fileSystem.isFSKitCapable {
            let containerID = FSContainerIdentifier()
            let label = probe.label ?? probe.fileSystem.displayName
            let recognized = FSProbeResult.recognized(name: label, containerID: containerID)
            reply(recognized, nil)
        } else {
            reply(FSProbeResult.notRecognized, nil)
        }
    }

    public func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable (FSVolume?, (any Error)?) -> Void
    ) {
        guard let blockResource = resource as? FSBlockDeviceResource else {
            reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL)))
            return
        }

        let reader = FSBlockDeviceIOBridge(resource: blockResource)
        let probeResult = SuperblockProbe.probe(reader: reader) ?? SuperblockProbe.probe(path: "/dev/\(blockResource.bsdName)")
        let volumeID = FSVolume.Identifier()
        let volumeName = FSFileName(string: probeResult?.label ?? probeResult?.fileSystem.displayName ?? "Linux Filesystem")
        let readOnly = !blockResource.isWritable

        if let probe = probeResult, probe.fileSystem.isCowFS {
            let cowKind: cowfs_kind_t = (probe.fileSystem == .xfs) ? COWFS_KIND_XFS : COWFS_KIND_BTRFS
            let cowVol = CowFSKitVolume(
                volumeID: volumeID,
                volumeName: volumeName,
                kind: cowKind,
                resource: blockResource,
                readOnly: readOnly
            )
            self.activeCowVolume = cowVol
            reply(cowVol, nil)
            return
        }

        if let probe = probeResult, probe.fileSystem == .hfs {
            let appleVol = AppleExplorerFSVolume(
                volumeID: volumeID,
                volumeName: volumeName,
                resource: blockResource
            )
            self.activeAppleVolume = appleVol
            reply(appleVol, nil)
            return
        }

        if let probe = probeResult, probe.fileSystem.isReadOnlySupported {
            let legacyVol = LegacyFSVolume(
                volumeID: volumeID,
                volumeName: volumeName,
                resource: blockResource
            )
            self.activeLegacyVolume = legacyVol
            reply(legacyVol, nil)
            return
        }

        let volume = Ext4FSVolume(
            volumeID: volumeID,
            volumeName: volumeName,
            resource: blockResource,
            readOnly: readOnly
        )

        self.activeVolume = volume
        reply(volume, nil)
    }

    public func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void
    ) {
        if let vol = activeVolume {
            vol.unmount {
                self.activeVolume = nil
                reply(nil)
            }
        } else if let cvol = activeCowVolume {
            cvol.unmount {
                self.activeCowVolume = nil
                reply(nil)
            }
        } else if let lvol = activeLegacyVolume {
            lvol.unmount {
                self.activeLegacyVolume = nil
                reply(nil)
            }
        } else if let avol = activeAppleVolume {
            avol.unmount {
                self.activeAppleVolume = nil
                reply(nil)
            }
        } else {
            reply(nil)
        }
    }
}
#endif
