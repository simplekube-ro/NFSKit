//
//  NFSSecurity.swift
//  NFSKit
//
//  NFS authentication security mode. Maps to `enum rpc_sec` in libnfs.
//  Must be configured before calling `NFSClient.connect(export:)` —
//  libnfs reads the security setting during mount negotiation.
//

import Foundation
import nfs

/// NFS authentication security modes.
///
/// Pass a value to ``NFSClient/setSecurity(_:)`` before calling
/// ``NFSClient/connect(export:)`` to configure the authentication
/// mechanism used for all NFS RPCs.
///
/// - Important: The default ``system`` (`AUTH_SYS`) mode provides **no encryption**,
///   **no message integrity**, and UID/GID-based authentication that can be forged by
///   any client on the network. For sensitive deployments, use ``kerberos5p`` which
///   provides Kerberos 5 authentication with data privacy (encryption).
///
/// - Note: Kerberos modes require the host to have a valid Kerberos
///   configuration and the libnfs build to have been compiled with
///   `HAVE_LIBKRB5`. Attempting to use them without KRB5 support will
///   result in an error from the server during mount.
public enum NFSSecurity: Sendable {

    /// System / AUTH_SYS authentication (default). Maps to `RPC_SEC_UNDEFINED`.
    case system

    /// Kerberos 5 authentication. Maps to `RPC_SEC_KRB5`.
    case kerberos5

    /// Kerberos 5 with data integrity checking. Maps to `RPC_SEC_KRB5I`.
    case kerberos5i

    /// Kerberos 5 with data privacy (encryption). Maps to `RPC_SEC_KRB5P`.
    case kerberos5p

    /// The underlying `rpc_sec` C enum value for this security mode.
    var rpcSecValue: rpc_sec {
        switch self {
        case .system:     return RPC_SEC_UNDEFINED
        case .kerberos5:  return RPC_SEC_KRB5
        case .kerberos5i: return RPC_SEC_KRB5I
        case .kerberos5p: return RPC_SEC_KRB5P
        }
    }
}
