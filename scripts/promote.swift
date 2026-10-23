import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else { exit(2) }
let staged = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
// Darwin's documented RENAME_SWAP exchanges both directory names atomically.
// If interrupted, the previous or new verified package remains at output.
let flags = FileManager.default.fileExists(atPath: output) ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
guard renamex_np(staged, output, flags) == 0 else {
    fputs("Could not promote verified package; staging and previous output are kept.\n", stderr)
    exit(1)
}
if flags == UInt32(RENAME_SWAP) {
    print("Previous package retained for verified cleanup: \(staged)")
}
