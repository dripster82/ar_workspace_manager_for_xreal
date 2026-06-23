import CXPCAuditToken
import Foundation
import PrivilegedHelperShared
import Security

/// Verifies that an XPC peer is the genuine VR Desktop app before the helper runs anything as root.
/// Without this check, *any* local process could connect to the daemon's Mach service and ask root to
/// delete files — a privilege-escalation hole. We identify the peer by its audit token (race-free,
/// unlike PID) and require its code signature to be Apple-anchored, signed by our Developer Team, and
/// carry our bundle identifier.
enum ClientValidator {
    static func isValidClient(_ connection: NSXPCConnection) -> Bool {
        #if DEBUG
        // Local development: the app is self-signed, so the Developer-ID requirement below can't be
        // satisfied. Skip it for debug builds only. Release builds always enforce the full check.
        return true
        #else
        guard HelperConstants.teamID != "REPLACE_WITH_TEAM_ID" else {
            NSLog("VRDesktopHelper: teamID not configured — refusing all clients (fail-closed)")
            return false
        }
        var token = connection.auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }

        // anchor apple generic + Developer-ID intermediate marker + our team + our bundle id.
        let requirementText = """
        identifier "\(HelperConstants.appBundleID)" and anchor apple generic and \
        certificate leaf[subject.OU] = "\(HelperConstants.teamID)" and \
        certificate 1[field.1.2.840.113635.100.6.2.6] exists
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }

        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        #endif
    }
}
