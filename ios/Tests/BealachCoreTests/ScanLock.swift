import Foundation

// bealach_scan_segment uses a static frame staging buffer (not reentrant).
// Swift Testing runs test suites concurrently, so all scan calls must serialize.
let scanLock = NSLock()
