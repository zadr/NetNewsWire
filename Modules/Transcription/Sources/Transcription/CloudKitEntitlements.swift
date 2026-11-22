//
//  CloudKitEntitlements.swift
//  Transcription
//

import Foundation
#if os(macOS)
import Security
#endif

/// Reads this process’s own code-signing entitlements.
///
/// Creating a `CKContainer` for a container the app isn’t entitled to raises an exception,
/// so check here first. Builds signed without iCloud (such as local builds without a provisioning
/// profile) don’t have the entitlement.
public enum CloudKitEntitlements {

	static let containerIdentifiersKey = "com.apple.developer.icloud-container-identifiers"
	static let servicesKey = "com.apple.developer.icloud-services"

	/// True when the app is signed with CloudKit access to the container.
	public static func isEntitled(toContainer containerIdentifier: String) -> Bool {
		guard let entitlements = currentEntitlements() else {
			return false
		}
		return isEntitled(toContainer: containerIdentifier, entitlements: entitlements)
	}

	static func isEntitled(toContainer containerIdentifier: String, entitlements: [String: Any]) -> Bool {
		guard let containers = entitlements[containerIdentifiersKey] as? [String], containers.contains(containerIdentifier) else {
			return false
		}
		guard let services = entitlements[servicesKey] as? [String] else {
			return false
		}
		return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
	}
}

extension CloudKitEntitlements {

	static func currentEntitlements() -> [String: Any]? {
		#if os(macOS)
		guard let task = SecTaskCreateFromSelf(nil) else {
			return nil
		}
		var entitlements = [String: Any]()
		for key in [containerIdentifiersKey, servicesKey] {
			if let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) {
				entitlements[key] = value
			}
		}
		return entitlements
		#else
		// SecTask isn’t available on iOS, so read the entitlements from the executable’s code signature.
		guard let executableURL = Bundle.main.executableURL,
			  let data = try? Data(contentsOf: executableURL, options: .alwaysMapped) else {
			return nil
		}
		return entitlements(fromExecutable: data)
		#endif
	}

	/// The entitlements in a Mach-O executable’s code signature: a thin 64-bit image, or the slice
	/// for this CPU in a universal binary. Nil when there’s no signature or no entitlements.
	static func entitlements(fromExecutable data: Data) -> [String: Any]? {
		let reader = ByteReader(data: data)
		guard let magic = reader.uint32(at: 0, bigEndian: true) else {
			return nil
		}

		switch magic {
		case MachO.fatMagic, MachO.fatMagic64:
			guard let slice = currentSlice(in: reader, is64: magic == MachO.fatMagic64) else {
				return nil
			}
			return entitlements(fromImageAt: slice, reader: reader)
		default:
			return entitlements(fromImageAt: 0, reader: reader)
		}
	}
}

private enum MachO {
	static let fatMagic: UInt32 = 0xcafebabe
	static let fatMagic64: UInt32 = 0xcafebabf
	static let magic64: UInt32 = 0xfeedfacf
	static let loadCommandCodeSignature: UInt32 = 0x1d
	static let cpuTypeARM64: UInt32 = 0x0100000c
	static let cpuTypeX86_64: UInt32 = 0x01000007

	// Code signature blobs are big-endian.
	static let superBlobMagic: UInt32 = 0xfade0cc0
	static let entitlementsBlobMagic: UInt32 = 0xfade7171
	static let entitlementsSlot: UInt32 = 5
}

private extension CloudKitEntitlements {

	static func currentSlice(in reader: ByteReader, is64: Bool) -> Int? {
		#if arch(arm64)
		let cpuType = MachO.cpuTypeARM64
		#else
		let cpuType = MachO.cpuTypeX86_64
		#endif

		guard let count = reader.uint32(at: 4, bigEndian: true) else {
			return nil
		}
		let archSize = is64 ? 32 : 20
		for index in 0..<Int(count) {
			let archOffset = 8 + index * archSize
			guard reader.uint32(at: archOffset, bigEndian: true) == cpuType else {
				continue
			}
			if is64 {
				return reader.uint64(at: archOffset + 8, bigEndian: true).map { Int($0) }
			}
			return reader.uint32(at: archOffset + 8, bigEndian: true).map { Int($0) }
		}
		return nil
	}

	static func entitlements(fromImageAt imageOffset: Int, reader: ByteReader) -> [String: Any]? {
		// Mach-O headers are in the CPU’s byte order: little-endian on every supported CPU.
		guard reader.uint32(at: imageOffset, bigEndian: false) == MachO.magic64,
			  let commandCount = reader.uint32(at: imageOffset + 16, bigEndian: false) else {
			return nil
		}

		var commandOffset = imageOffset + 32
		for _ in 0..<commandCount {
			guard let command = reader.uint32(at: commandOffset, bigEndian: false),
				  let commandSize = reader.uint32(at: commandOffset + 4, bigEndian: false), commandSize >= 8 else {
				return nil
			}
			if command == MachO.loadCommandCodeSignature {
				guard let dataOffset = reader.uint32(at: commandOffset + 8, bigEndian: false) else {
					return nil
				}
				return entitlements(fromSignatureAt: imageOffset + Int(dataOffset), reader: reader)
			}
			commandOffset += Int(commandSize)
		}
		return nil
	}

	static func entitlements(fromSignatureAt signatureOffset: Int, reader: ByteReader) -> [String: Any]? {
		guard reader.uint32(at: signatureOffset, bigEndian: true) == MachO.superBlobMagic,
			  let blobCount = reader.uint32(at: signatureOffset + 8, bigEndian: true) else {
			return nil
		}

		for index in 0..<Int(blobCount) {
			let indexOffset = signatureOffset + 12 + index * 8
			guard let slot = reader.uint32(at: indexOffset, bigEndian: true),
				  let blobOffset = reader.uint32(at: indexOffset + 4, bigEndian: true) else {
				return nil
			}
			guard slot == MachO.entitlementsSlot else {
				continue
			}
			let blobStart = signatureOffset + Int(blobOffset)
			guard reader.uint32(at: blobStart, bigEndian: true) == MachO.entitlementsBlobMagic,
				  let blobLength = reader.uint32(at: blobStart + 4, bigEndian: true), blobLength >= 8,
				  let plistData = reader.bytes(at: blobStart + 8, count: Int(blobLength) - 8) else {
				return nil
			}
			return (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any]
		}
		return nil
	}
}

private struct ByteReader {

	let data: Data

	func uint32(at offset: Int, bigEndian: Bool) -> UInt32? {
		guard let slice = bytes(at: offset, count: 4) else {
			return nil
		}
		let value = slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
		return bigEndian ? value : value.byteSwapped
	}

	func uint64(at offset: Int, bigEndian: Bool) -> UInt64? {
		guard let slice = bytes(at: offset, count: 8) else {
			return nil
		}
		let value = slice.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
		return bigEndian ? value : value.byteSwapped
	}

	func bytes(at offset: Int, count: Int) -> Data? {
		guard offset >= 0, count >= 0, offset <= data.count - count else {
			return nil
		}
		let start = data.startIndex + offset
		return data[start..<(start + count)]
	}
}
