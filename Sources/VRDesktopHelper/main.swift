import Foundation
import PrivilegedHelperShared

// Entry point for the privileged LaunchDaemon (runs as root, registered via SMAppService). It does
// nothing on its own: it waits for the app to connect over XPC, verifies the caller is the genuine
// signed VR Desktop (ClientValidator), and then services narrow profile-removal requests.
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
NSLog("VRDesktopHelper: listening on \(HelperConstants.machServiceName)")
dispatchMain()
