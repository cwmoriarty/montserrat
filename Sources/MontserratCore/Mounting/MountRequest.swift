import Foundation

public struct MountRequest: Sendable {
    public let target: String
    public var mountPoint: URL?
    public var readOnly: Bool
    public var owner: (uid: UInt32, gid: UInt32)?
    public var allowUnclean: Bool
    public var timeout: Double
    public var cacheSize: String
    public var noAtime: Bool
    public var suppressSpotlight: Bool

    public init(
        target: String,
        readOnly: Bool = false,
        mountPoint: URL? = nil,
        owner: (uid: UInt32, gid: UInt32)? = nil,
        allowUnclean: Bool = false,
        timeout: Double = 30.0,
        cacheSize: String = "128M",
        noAtime: Bool = true,
        suppressSpotlight: Bool = true
    ) {
        self.target = target
        self.readOnly = readOnly
        self.mountPoint = mountPoint
        self.owner = owner
        self.allowUnclean = allowUnclean
        self.timeout = timeout
        self.cacheSize = cacheSize
        self.noAtime = noAtime
        self.suppressSpotlight = suppressSpotlight
    }
}
