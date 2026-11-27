import Darwin
import Foundation
import Security

/// HTTP clients authenticate separately from the process-private stdio transport.
enum HTTPAccess {
    static let maxBody = 8 << 20
    static let maxHead = 16 << 10
    static let tokenURL = root.appendingPathComponent("http-mcp-token")

    static func token() throws -> String {
        if let configured = ProcessInfo.processInfo.environment["BEANPOD_MCP_TOKEN"] {
            guard validToken(configured) else { throw Failure("BEANPOD_MCP_TOKEN must contain 64 hexadecimal characters") }
            return configured
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure("Could not generate the HTTP MCP credential")
        }
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        var template = Array((tokenURL.path + ".XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw Failure("Could not create the HTTP MCP credential") }
        let staging = String(cString: template)
        defer { unlink(staging) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try output.write(contentsOf: Data(fresh.utf8))
        try output.close()
        // Publish a complete credential atomically; a concurrent first launch keeps the winner.
        if link(staging, tokenURL.path) != 0, errno != EEXIST {
            throw Failure("Could not create the HTTP MCP credential")
        }
        let input = open(tokenURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw Failure("Could not open the HTTP MCP credential") }
        let file = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_size == 64,
              let data = try file.read(upToCount: 65), let value = String(data: data, encoding: .utf8), validToken(value) else {
            throw Failure("HTTP MCP credential must be an owner-only regular file containing 64 hexadecimal characters")
        }
        return value
    }

    static func validToken(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func authorized(_ value: String?, token: String) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let supplied = Array(parts[1].utf8), expected = Array(token.utf8)
        guard supplied.count == expected.count else { return false }
        return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    struct Failure: Error, CustomStringConvertible { let description: String; init(_ message: String) { description = message } }
}

struct HTTPHead {
    let method: String
    let path: String
    let headers: [String: String]
    let length: Int

    init(_ data: Data) throws {
        guard data.count <= HTTPAccess.maxHead, data.allSatisfy({ $0 < 128 }),
              let text = String(data: data, encoding: .utf8) else { throw HTTPAccess.Failure("400 Bad Request") }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(parts[2])) else { throw HTTPAccess.Failure("400 Bad Request") }
        method = String(parts[0]); path = String(parts[1])
        var parsed: [String: String] = [:]
        let allowed = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz".utf8)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPAccess.Failure("400 Bad Request") }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ allowed.contains($0) }), parsed[name] == nil,
                  value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 && $0 != 127 }) else { throw HTTPAccess.Failure("400 Bad Request") }
            parsed[name] = value
        }
        guard parsed["transfer-encoding"] == nil else { throw HTTPAccess.Failure("400 Bad Request") }
        if let raw = parsed["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(raw) else { throw HTTPAccess.Failure("400 Bad Request") }
            guard count <= HTTPAccess.maxBody else { throw HTTPAccess.Failure("413 Payload Too Large") }
            length = count
        } else {
            guard method != "POST" else { throw HTTPAccess.Failure("411 Length Required") }
            length = 0
        }
        headers = parsed
    }

    func rejection(port: UInt16, token: String) -> String? {
        guard let host = headers["host"]?.lowercased(), ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host),
              headers["origin"] == nil, !headers.keys.contains(where: { $0.hasPrefix("sec-fetch-") }) else { return "403 Forbidden" }
        guard HTTPAccess.authorized(headers["authorization"], token: token) else { return "401 Unauthorized" }
        if method == "GET", path == "/health" { return nil }
        guard path == "/mcp" else { return "404 Not Found" }
        guard method == "POST" else { return "405 Method Not Allowed" }
        let type = headers["content-type"]?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        guard type == "application/json" else { return "415 Unsupported Media Type" }
        return nil
    }
}
