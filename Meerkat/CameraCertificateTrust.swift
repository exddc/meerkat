import Foundation
import Darwin

enum CameraCertificateTrust {
    static func allows(url: URL, host: String) -> Bool {
        let brackets = CharacterSet(charactersIn: "[]")
        let host = host.trimmingCharacters(in: brackets).lowercased()
        guard url.scheme == "https",
              url.host?.trimmingCharacters(in: brackets).lowercased() == host,
              url.path == "/flv" else { return false }
        var address = in_addr()
        if inet_pton(AF_INET, host, &address) == 1 {
            let value = UInt32(bigEndian: address.s_addr)
            return value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8
                || value >> 16 == 0xa9fe || value >> 22 == 0x191
        }
        var address6 = in6_addr()
        guard inet_pton(AF_INET6, host, &address6) == 1 else { return false }
        return withUnsafeBytes(of: address6) { bytes in
            bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
    }
}
