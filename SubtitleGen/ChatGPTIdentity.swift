import Foundation
import CryptoKit
import Security

enum ChatGPTIdentity {
    struct Header: Decodable { let alg: String; let kid: String }
    struct JWK: Decodable { let kty: String; let kid: String; let alg: String?; let use: String?; let n: String?; let e: String?; let crv: String?; let x: String?; let y: String? }
    struct Keys: Decodable { let keys: [JWK] }
    struct Claims: Decodable {
        let iss: String; let sub: String; let exp: Double; let iat: Double; let nbf: Double?
        let aud: Audience; let nonce: String; let email: String?; let azp: String?
        enum Audience: Decodable {
            case one(String), many([String])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let value = try? c.decode(String.self) { self = .one(value) }
                else { self = .many(try c.decode([String].self)) }
            }
            func contains(_ value: String) -> Bool {
                switch self { case .one(let a): return a == value; case .many(let a): return a.contains(value) }
            }
            var multiple: Bool { if case .many(let values) = self { return values.count > 1 }; return false }
        }
    }
    static func header(_ token: String) throws -> Header {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.utf8.count < 32_768, let data = Data(base64URL: String(parts[0])),
              let header = try? JSONDecoder().decode(Header.self, from: data),
              ["RS256", "ES256"].contains(header.alg) else { throw ChatGPTFailure.invalidIdentity }
        return header
    }
    static func validate(_ token: String, keys: [JWK], clientID: String, nonce: String, now: Date = Date()) throws -> Claims {
        let header = try header(token)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard let signature = Data(base64URL: String(parts[2])),
              let payload = Data(base64URL: String(parts[1])),
              let key = keys.first(where: { $0.kid == header.kid && ($0.alg == nil || $0.alg == header.alg) && ($0.use == nil || $0.use == "sig") }) else {
            throw ChatGPTFailure.invalidIdentity
        }
        let signed = Data("\(parts[0]).\(parts[1])".utf8)
        var valid = false
        if header.alg == "RS256", key.kty == "RSA", let n = key.n.flatMap({ Data(base64URL: $0) }),
           let e = key.e.flatMap({ Data(base64URL: $0) }), (256...512).contains(n.count), (1...8).contains(e.count) {
            let representation = der(tag: 0x30, data: integer(n) + integer(e))
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
            if let rsa = SecKeyCreateWithData(representation as CFData, attributes as CFDictionary, nil) {
                valid = SecKeyVerifySignature(rsa, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
            }
        } else if header.alg == "ES256", key.kty == "EC", key.crv == "P-256",
                  let x = key.x.flatMap({ Data(base64URL: $0) }), let y = key.y.flatMap({ Data(base64URL: $0) }),
                  x.count == 32, y.count == 32, signature.count == 64,
                  let ec = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            valid = ec.isValidSignature(sig, for: signed)
        }
        guard valid, let claims = try? JSONDecoder().decode(Claims.self, from: payload),
              claims.iss == ChatGPTOAuth.issuer, claims.aud.contains(clientID), !claims.sub.isEmpty,
              (!claims.aud.multiple || claims.azp == clientID),
              claims.nonce == nonce, claims.exp.isFinite, claims.iat.isFinite,
              claims.exp > now.timeIntervalSince1970 - 5, claims.iat <= now.timeIntervalSince1970 + 5,
              claims.exp > claims.iat, claims.nbf.map({ $0 <= now.timeIntervalSince1970 + 5 }) ?? true else {
            throw ChatGPTFailure.invalidIdentity
        }
        return claims
    }
    private static func integer(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return der(tag: 2, data: bytes)
    }
    private static func der(tag: UInt8, data: Data) -> Data {
        var length = Data()
        if data.count < 128 { length.append(UInt8(data.count)) }
        else {
            var value = data.count; var bytes: [UInt8] = []
            while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
            length.append(0x80 | UInt8(bytes.count)); length.append(contentsOf: bytes)
        }
        return Data([tag]) + length + data
    }
}
