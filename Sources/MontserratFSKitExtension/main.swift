import Foundation
import MontserratFSKit

#if canImport(FSKit)
import FSKit

@_silgen_name("NSExtensionMain")
@discardableResult
func NSExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

_ = NSExtensionMain(CommandLine.argc, CommandLine.unsafeArgv)
#else
fputs("FSKit is not available on this platform.\n", stderr)
exit(1)
#endif
