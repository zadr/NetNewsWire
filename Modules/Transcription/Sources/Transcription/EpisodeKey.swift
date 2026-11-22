//
//  EpisodeKey.swift
//  Transcription
//

import Foundation
import CryptoKit

/// Identifies a podcast episode by its audio (enclosure) URL, so every copy of an episode —
/// in any feed, account, or device — shares one transcript.
///
/// The raw value is a SHA-256 hash of the normalized URL: safe as a file name and a CloudKit record name.
public struct EpisodeKey: Hashable, Codable, Sendable, CustomStringConvertible {

	public let rawValue: String

	public init?(enclosureURL: String) {
		guard let normalizedURLString = Self.normalizedURLString(enclosureURL) else {
			return nil
		}
		self.rawValue = SHA256.hash(data: Data(normalizedURLString.utf8)).hexString
	}

	/// Accepts only a raw value made by `init(enclosureURL:)` — 64 lowercase hex digits.
	public init?(rawValue: String) {
		guard rawValue.count == 64, rawValue.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
			return nil
		}
		self.rawValue = rawValue
	}

	public var description: String {
		rawValue
	}

	/// The parts of a URL that identify the audio, without the parts that vary between copies of a feed:
	/// the scheme (http or https), letter case of the host, default ports, credentials, fragment,
	/// `utm_` tracking parameters, the order of query parameters, and percent-encoding differences.
	/// Path case and other query parameters are kept, since servers may treat them as significant.
	static func normalizedURLString(_ urlString: String) -> String? {
		let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let components = URLComponents(string: trimmedURLString),
			  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
			  var host = components.percentEncodedHost?.lowercased(), !host.isEmpty else {
			return nil
		}

		while host.hasSuffix(".") {
			host.removeLast()
		}

		var normalized = host
		if let port = components.port, port != 80 && port != 443 {
			normalized += ":\(port)"
		}

		let path = normalizedPercentEncoding(components.percentEncodedPath)
		normalized += path.isEmpty ? "/" : path

		let queryItems = (components.percentEncodedQueryItems ?? [])
			.filter { !$0.name.lowercased().hasPrefix("utm_") }
			.map { (name: normalizedPercentEncoding($0.name), value: $0.value.map(normalizedPercentEncoding)) }
			.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
		if !queryItems.isEmpty {
			normalized += "?" + queryItems.map { item in
				item.value.map { "\(item.name)=\($0)" } ?? item.name
			}.joined(separator: "&")
		}

		return normalized
	}
}

private extension EpisodeKey {

	/// Decodes percent-encoded unreserved characters and uppercases the remaining escapes,
	/// so `%7e`, `%7E`, and `~` compare equal.
	static func normalizedPercentEncoding(_ string: String) -> String {
		guard string.contains("%") else {
			return string
		}

		var result = ""
		var index = string.startIndex
		while index < string.endIndex {
			let character = string[index]
			if character == "%",
			   let firstHexIndex = string.index(index, offsetBy: 1, limitedBy: string.endIndex), firstHexIndex < string.endIndex,
			   let secondHexIndex = string.index(index, offsetBy: 2, limitedBy: string.endIndex), secondHexIndex < string.endIndex,
			   let byte = UInt8(String(string[firstHexIndex...secondHexIndex]), radix: 16) {
				let scalar = Unicode.Scalar(byte)
				if isUnreserved(scalar) {
					result.unicodeScalars.append(scalar)
				} else {
					result += String(format: "%%%02X", byte)
				}
				index = string.index(after: secondHexIndex)
			} else {
				result.append(character)
				index = string.index(after: index)
			}
		}
		return result
	}

	static func isUnreserved(_ scalar: Unicode.Scalar) -> Bool {
		switch scalar {
		case "A"..."Z", "a"..."z", "0"..."9", "-", ".", "_", "~":
			return true
		default:
			return false
		}
	}
}
