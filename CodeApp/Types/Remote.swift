//
//  RemoteType.swift
//  Code
//
//  Created by Ken Chung 10/11/2022.
//

import Foundation

enum RemoteType: String, CaseIterable, Identifiable {
    case sftp
    case ftp
    case ftps
    case android
    var id: String { self.rawValue }
}

struct RemoteHost: Codable {
    var url: String
    var useKeyAuth: Bool  // Legacy flag for in-file id_rsa key authentication (.ssh/id_rsa)
    var displayName: String?
    var privateKeyContentKeychainID: String?
    var privateKeyPath: String?
    var jumpServerUrl: String?
    // Added for Android LAN remote support: reconnect silently on relaunch
    // if this was the last-opened workspace. Optional so previously-saved
    // hosts (encoded before this field existed) still decode correctly.
    var reconnectAutomatically: Bool? = nil

    var rowDisplayName: String {
        displayName ?? URL(string: self.url)?.host ?? ""
    }
}

enum RemoteAuthenticationMode {
    case plainUsernamePassword(URLCredential)
    // File path of the ssh keys, default to Documents/.ssh
    case inFileSSHKey(URLCredential, URL?)
    case inMemorySSHKey(URLCredential, String)

    var credentials: URLCredential {
        switch self {
        case .inFileSSHKey(let credentials, _), .inMemorySSHKey(let credentials, _),
            .plainUsernamePassword(let credentials):
            return credentials
        }
    }
}
