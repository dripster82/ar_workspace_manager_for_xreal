#ifndef CXPCAuditToken_h
#define CXPCAuditToken_h

#import <Foundation/Foundation.h>
#import <bsm/libbsm.h> // audit_token_t

/// `auditToken` is a real but undocumented property on NSXPCConnection. Redeclaring it here lets the
/// privileged helper read the connecting client's audit token — the *race-free* identity needed to
/// verify the caller's code signature before honouring a root request. (PID-based identity, the only
/// public alternative, is subject to PID-reuse races; the audit token is not.) The getter is provided
/// by Foundation at runtime; this header just makes it visible to Swift.
@interface NSXPCConnection (CXPCAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

#endif /* CXPCAuditToken_h */
