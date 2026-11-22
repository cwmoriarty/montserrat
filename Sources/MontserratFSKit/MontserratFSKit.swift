import Foundation
import MontserratCore
import CExt2FS

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

/// Ext4 Native FSKit Volume implementation
@available(macOS 15.4, *)
public final class Ext4FSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, @unchecked Sendable {
    private var ext4Ctx: OpaquePointer?
    public let rawDevicePath: String
    public let isReadOnly: Bool

    public init(volumeID: FSVolume.Identifier, volumeName: FSFileName, devicePath: String, readOnly: Bool = false) {
        self.rawDevicePath = devicePath
        self.isReadOnly = readOnly
        super.init(volumeID: volumeID, volumeName: volumeName)

        var ctx: OpaquePointer?
        let rc = ext4_bridge_mount(devicePath, readOnly ? 1 : 0, &ctx)
        if rc == 0 {
            self.ext4Ctx = ctx
        }
    }

    deinit {
        if let ctx = ext4Ctx {
            ext4_bridge_unmount(ctx)
            ext4Ctx = nil
        }
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
        reply(nil, nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))
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
        reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)))
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
        attrs.uid = cAttrs.uid
        attrs.gid = cAttrs.gid
        attrs.mode = cAttrs.mode
        attrs.size = cAttrs.size
        attrs.allocSize = cAttrs.alloc_size
        attrs.linkCount = cAttrs.link_count
        attrs.flags = cAttrs.flags

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

        if newAttributes.isValid(.mode) {
            cAttrs.mode = newAttributes.mode
            mask |= 0x01
        }
        if newAttributes.isValid(.uid) {
            cAttrs.uid = newAttributes.uid
            mask |= 0x02
        }
        if newAttributes.isValid(.gid) {
            cAttrs.gid = newAttributes.gid
            mask |= 0x04
        }
        if newAttributes.isValid(.size) {
            cAttrs.size = newAttributes.size
            mask |= 0x20
        }

        if mask != 0 {
            let rc = ext4_bridge_set_attrs(ctx, ino, mask, &cAttrs)
            if rc != 0 {
                reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(-rc)))
                return
            }
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

/// Ext4 Native FSKit Unary File System Extension
@available(macOS 15.4, *)
public final class Ext4FSUnaryFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {
    public var activeVolume: Ext4FSVolume?

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

        let bsdName = "/dev/\(blockResource.bsdName)"
        let probeResult = SuperblockProbe.probe(path: bsdName)
        if let probe = probeResult, probe.fileSystem.isExt {
            let containerID = FSContainerIdentifier()
            let label = probe.label ?? "Linux ext4"
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

        let bsdName = "/dev/\(blockResource.bsdName)"
        let volumeID = FSVolume.Identifier()
        let volumeName = FSFileName(string: "Linux Filesystem")
        let readOnly = !blockResource.isWritable

        let volume = Ext4FSVolume(
            volumeID: volumeID,
            volumeName: volumeName,
            devicePath: bsdName,
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
        } else {
            reply(nil)
        }
    }
}
#endif
