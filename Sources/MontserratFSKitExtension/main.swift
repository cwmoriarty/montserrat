import Foundation
import MontserratFSKit

#if canImport(FSKit)
import FSKit

@_silgen_name("NSExtensionMain")
@discardableResult
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

if #available(macOS 15.4, *) {
    _ = NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv)
} else {
    fputs("FSKit requires macOS 15.4 or later.\n", stderr)
    exit(1)
}
#else
fputs("FSKit is not available on this platform.\n", stderr)
exit(1)
#endif
