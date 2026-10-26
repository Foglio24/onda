// Tests version comparison and release-note parsing used by the in-app update check.
// Run from the repository root: bash Tools/UpdateCheck/run.sh
import Foundation

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

expect(AppVersion.isNewer("v1.5.1", than: "1.5.0"), "a patch release is newer")
expect(AppVersion.isNewer("1.10.0", than: "1.9.2"), "versions compare as numbers, not text")
expect(AppVersion.isNewer("2", than: "1.9.9"), "a shorter version can be newer")
expect(!AppVersion.isNewer("v1.5.0", than: "1.5.0"), "the same version is not an update")
expect(!AppVersion.isNewer("1.5", than: "1.5.0"), "missing parts count as zero")
expect(!AppVersion.isNewer("1.4.9", than: "1.5.0"), "an older release is not an update")
expect(AppVersion.components("V1.6.0-beta") == [1, 6, 0], "suffixes after the number are ignored")

let body = """
A new Home.\r
\r
## Changed\r
- **A new Home**, all on Liquid Glass:\r
  - **Quick access.** Tiles.\r
* Star bullets work too\r
### Install\r
**Full changelog:** https://github.com/Foglio24/onda/compare/v1.4.1...v1.5.0\r
"""
let blocks = ReleaseNoteBlock.parse(body)
expect(blocks == [
    .paragraph("A new Home."),
    .heading("Changed"),
    .bullet("**A new Home**, all on Liquid Glass:", level: 0),
    .bullet("**Quick access.** Tiles.", level: 1),
    .bullet("Star bullets work too", level: 0),
    .heading("Install"),
    .paragraph("**Full changelog:** https://github.com/Foglio24/onda/compare/v1.4.1...v1.5.0"),
], "release notes split into paragraphs, headings and nested bullets (CRLF too): \(blocks)")
expect(ReleaseNoteBlock.parse("").isEmpty, "an empty body has no blocks")

print("UpdateCheck: \(checks) checks passed")
