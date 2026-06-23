import Foundation
import PrivilegedHelperShared

/// Accepts XPC connections only from a verified client, then wires up the HelperProtocol service.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard ClientValidator.isValidClient(newConnection) else {
            NSLog("VRDesktopHelper: rejected connection from unverified client")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}
