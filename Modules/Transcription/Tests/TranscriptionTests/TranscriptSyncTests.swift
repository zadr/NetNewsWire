//
//  TranscriptSyncTests.swift
//  TranscriptionTests
//

import Foundation
import CloudKit
import Testing
@testable import Transcription

@Suite struct EpisodeKeyTests {

	@Test func equivalentURLsShareAKey() throws {
		let key = try #require(EpisodeKey(enclosureURL: "https://cdn.example.com/shows/42.mp3?b=2&a=1"))
		let equivalentURLs = [
			"http://cdn.example.com/shows/42.mp3?b=2&a=1",
			"HTTPS://CDN.Example.COM/shows/42.mp3?a=1&b=2",
			"https://cdn.example.com:443/shows/42.mp3?a=1&b=2#t=30",
			"http://cdn.example.com:80/shows/42.mp3?a=1&b=2",
			"https://cdn.example.com./shows/42.mp3?a=1&b=2",
			"  https://user:pass@cdn.example.com/shows/42.mp3?a=1&b=2&utm_source=rss&UTM_Medium=x \n",
			"https://cdn.example.com/%73hows/42.mp3?a=1&b=2"
		]
		for url in equivalentURLs {
			#expect(EpisodeKey(enclosureURL: url) == key, "\(url)")
		}
	}

	@Test func differentEpisodesHaveDifferentKeys() throws {
		let key = try #require(EpisodeKey(enclosureURL: "https://cdn.example.com/shows/42.mp3?id=1"))
		let differentURLs = [
			"https://cdn.example.com/shows/43.mp3?id=1",
			"https://cdn.example.com/Shows/42.mp3?id=1",
			"https://cdn.example.com/shows/42.mp3?id=2",
			"https://cdn.example.com/shows/42.mp3",
			"https://other.example.com/shows/42.mp3?id=1",
			"https://cdn.example.com:8443/shows/42.mp3?id=1"
		]
		for url in differentURLs {
			#expect(EpisodeKey(enclosureURL: url) != key, "\(url)")
		}
	}

	@Test func normalizedURLString() {
		#expect(EpisodeKey.normalizedURLString("HTTP://Example.com") == "example.com/")
		#expect(EpisodeKey.normalizedURLString("https://example.com/a%2fb%7e?q=%e2%9c%93") == "example.com/a%2Fb~?q=%E2%9C%93")
		#expect(EpisodeKey.normalizedURLString("https://example.com/a?flag&z=1") == "example.com/a?flag&z=1")
	}

	@Test func unusableURLsHaveNoKey() {
		#expect(EpisodeKey(enclosureURL: "") == nil)
		#expect(EpisodeKey(enclosureURL: "/relative/42.mp3") == nil)
		#expect(EpisodeKey(enclosureURL: "file:///Users/someone/42.mp3") == nil)
		#expect(EpisodeKey(enclosureURL: "ftp://example.com/42.mp3") == nil)
	}

	@Test func rawValueIsAHash() throws {
		let key = try #require(EpisodeKey(enclosureURL: "https://example.com/42.mp3"))
		#expect(key.rawValue.count == 64)
		#expect(EpisodeKey(rawValue: key.rawValue) == key)
		#expect(EpisodeKey(rawValue: key.rawValue.uppercased()) == nil)
		#expect(EpisodeKey(rawValue: "not a key") == nil)
	}
}

@Suite struct EpisodeTranscriptStoreTests {

	@Test func episodeTranscriptsAreSeparateFromArticleTranscripts() throws {
		let store = TranscriptStore(folderURL: temporaryFolderURL())
		defer {
			try? FileManager.default.removeItem(at: store.folderURL)
		}
		let episodeKey = try #require(EpisodeKey(enclosureURL: "https://example.com/a.mp3"))
		let transcript = sampleTranscript()

		#expect(!store.hasTranscript(forEpisodeKey: episodeKey))
		try store.save(transcript, forEpisodeKey: episodeKey)

		#expect(store.hasTranscript(forEpisodeKey: episodeKey))
		#expect(store.transcript(forEpisodeKey: episodeKey) == transcript)
		#expect(!store.hasTranscript(forArticleID: episodeKey.rawValue))

		store.removeTranscript(forEpisodeKey: episodeKey)
		#expect(store.transcript(forEpisodeKey: episodeKey) == nil)
	}
}

@Suite struct TranscriptRecordTests {

	let zoneID = CKRecordZone.ID(zoneName: TranscriptCloudSync.zoneName, ownerName: CKCurrentUserDefaultName)

	@Test func transcriptRoundTripsThroughARecord() throws {
		let folderURL = temporaryFolderURL()
		defer {
			try? FileManager.default.removeItem(at: folderURL)
		}
		let transcript = sampleTranscript()
		let episodeKey = try #require(EpisodeKey(enclosureURL: transcript.audioURL))
		let transcriptRecord = TranscriptCloudRecord(transcript: transcript, episodeKey: episodeKey, engineVersion: "Engine 1")

		try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
		let fileURL = folderURL.appendingPathComponent("transcript.json")
		try transcript.jsonData().write(to: fileURL)

		let record = CKRecord(recordType: TranscriptCloudRecord.recordType, recordID: TranscriptCloudRecord.recordID(for: episodeKey, zoneID: zoneID))
		transcriptRecord.apply(to: record, transcriptFileURL: fileURL)

		#expect(record.recordID.recordName == episodeKey.rawValue)
		#expect(record["enclosureURL"] as? String == transcript.audioURL)
		#expect(record["localeIdentifier"] as? String == "en_US")
		#expect(record["engineVersion"] as? String == "Engine 1")
		#expect(record["deleted"] as? Int == 0)

		let readRecord = try #require(TranscriptCloudRecord(record: record))
		#expect(readRecord == transcriptRecord)
		#expect(readRecord.syncVersion == TranscriptSyncVersion(modified: transcript.dateCreated, isDeleted: false))
		#expect(try TranscriptCloudRecord.transcript(from: record) == transcript)
	}

	@Test func tombstoneHasNoTranscript() throws {
		let folderURL = temporaryFolderURL()
		defer {
			try? FileManager.default.removeItem(at: folderURL)
		}
		let transcript = sampleTranscript()
		let episodeKey = try #require(EpisodeKey(enclosureURL: transcript.audioURL))
		try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
		let fileURL = folderURL.appendingPathComponent("transcript.json")
		try transcript.jsonData().write(to: fileURL)

		// A record that had a transcript becomes a tombstone.
		let record = CKRecord(recordType: TranscriptCloudRecord.recordType, recordID: TranscriptCloudRecord.recordID(for: episodeKey, zoneID: zoneID))
		TranscriptCloudRecord(transcript: transcript, episodeKey: episodeKey, engineVersion: nil).apply(to: record, transcriptFileURL: fileURL)
		let deletionDate = Date(timeIntervalSinceReferenceDate: 900_000_000)
		TranscriptCloudRecord.tombstone(episodeKey: episodeKey, enclosureURL: transcript.audioURL, modified: deletionDate).apply(to: record, transcriptFileURL: fileURL)

		#expect(record["transcript"] == nil)
		let readRecord = try #require(TranscriptCloudRecord(record: record))
		#expect(readRecord.isDeleted)
		#expect(readRecord.syncVersion == TranscriptSyncVersion(modified: deletionDate, isDeleted: true))
		#expect(try TranscriptCloudRecord.transcript(from: record) == nil)
	}

	@Test func invalidRecordsAreIgnored() throws {
		let episodeKey = try #require(EpisodeKey(enclosureURL: "https://example.com/a.mp3"))

		let otherType = CKRecord(recordType: "Other", recordID: TranscriptCloudRecord.recordID(for: episodeKey, zoneID: zoneID))
		otherType["modified"] = Date()
		#expect(TranscriptCloudRecord(record: otherType) == nil)

		let badName = CKRecord(recordType: TranscriptCloudRecord.recordType, recordID: CKRecord.ID(recordName: "not-a-key", zoneID: zoneID))
		badName["modified"] = Date()
		badName["deleted"] = 1
		#expect(TranscriptCloudRecord(record: badName) == nil)

		let noDate = CKRecord(recordType: TranscriptCloudRecord.recordType, recordID: TranscriptCloudRecord.recordID(for: episodeKey, zoneID: zoneID))
		noDate["deleted"] = 0
		#expect(TranscriptCloudRecord(record: noDate) == nil)
	}

	@Test func metadataOnlyRecordHasNoTranscript() throws {
		// Changes are fetched without transcripts, which are downloaded only for episodes on this device.
		let episodeKey = try #require(EpisodeKey(enclosureURL: "https://example.com/a.mp3"))
		let record = CKRecord(recordType: TranscriptCloudRecord.recordType, recordID: TranscriptCloudRecord.recordID(for: episodeKey, zoneID: zoneID))
		TranscriptCloudRecord(transcript: sampleTranscript(), episodeKey: episodeKey, engineVersion: nil).apply(to: record, transcriptFileURL: nil)

		let metadata = try #require(TranscriptCloudRecord(record: record))
		#expect(!metadata.isDeleted)
		#expect(try TranscriptCloudRecord.transcript(from: record) == nil)
		#expect(!TranscriptCloudRecord.metadataKeys.contains("transcript"))
	}

	@Test func newerFormatIsUnreadable() throws {
		let episodeKey = try #require(EpisodeKey(enclosureURL: "https://example.com/a.mp3"))
		var transcriptRecord = TranscriptCloudRecord(transcript: sampleTranscript(), episodeKey: episodeKey, engineVersion: nil)
		#expect(transcriptRecord.isReadable)
		transcriptRecord.formatVersion = Transcript.currentVersion + 1
		#expect(!transcriptRecord.isReadable)
	}
}

@Suite struct TranscriptSyncResolutionTests {

	let earlier = Date(timeIntervalSinceReferenceDate: 800_000_000)
	let later = Date(timeIntervalSinceReferenceDate: 800_000_100)

	func resolve(_ local: TranscriptSyncVersion?, _ remote: TranscriptSyncVersion?) -> TranscriptSyncResolution {
		TranscriptSyncResolution.resolve(local: local, remote: remote)
	}

	func transcript(_ date: Date) -> TranscriptSyncVersion {
		TranscriptSyncVersion(modified: date, isDeleted: false)
	}

	func tombstone(_ date: Date) -> TranscriptSyncVersion {
		TranscriptSyncVersion(modified: date, isDeleted: true)
	}

	@Test func missingSides() {
		#expect(resolve(nil, nil) == .inSync)
		#expect(resolve(nil, transcript(earlier)) == .takeRemote)
		#expect(resolve(nil, tombstone(earlier)) == .inSync)
		#expect(resolve(transcript(earlier), nil) == .keepLocal)
		#expect(resolve(tombstone(earlier), nil) == .inSync)
	}

	@Test func newestTranscriptWins() {
		#expect(resolve(transcript(later), transcript(earlier)) == .keepLocal)
		#expect(resolve(transcript(earlier), transcript(later)) == .takeRemote)
		#expect(resolve(transcript(earlier), transcript(earlier)) == .inSync)
	}

	@Test func tombstonesCompareByDate() {
		// Deleted after the other device transcribed: the delete wins.
		#expect(resolve(tombstone(later), transcript(earlier)) == .keepLocal)
		#expect(resolve(transcript(earlier), tombstone(later)) == .takeRemote)
		// Transcribed again after the delete: the new transcript wins.
		#expect(resolve(transcript(later), tombstone(earlier)) == .keepLocal)
		#expect(resolve(tombstone(earlier), transcript(later)) == .takeRemote)
		#expect(resolve(tombstone(earlier), tombstone(later)) == .inSync)
	}

	@Test func datesWithinASecondAreEqual() {
		// Transcript JSON stores whole seconds, so a transcript read back from disk may be a fraction older.
		let fractionLater = earlier.addingTimeInterval(0.6)
		#expect(resolve(transcript(earlier), transcript(fractionLater)) == .inSync)
		#expect(resolve(transcript(fractionLater), transcript(earlier)) == .inSync)
		// A tie goes to the delete.
		#expect(resolve(tombstone(earlier), transcript(fractionLater)) == .keepLocal)
		#expect(resolve(transcript(fractionLater), tombstone(earlier)) == .takeRemote)
	}
}

@Suite struct CloudKitEntitlementsTests {

	static let containerIdentifier = "iCloud.com.example.NetNewsWire.Transcripts"

	@Test func entitlementsNeedContainerAndCloudKit() {
		let key = CloudKitEntitlements.containerIdentifiersKey
		let servicesKey = CloudKitEntitlements.servicesKey
		let container = Self.containerIdentifier

		#expect(CloudKitEntitlements.isEntitled(toContainer: container, entitlements: [key: [container], servicesKey: ["CloudKit"]]))
		#expect(!CloudKitEntitlements.isEntitled(toContainer: container, entitlements: [key: ["iCloud.com.example.Other"], servicesKey: ["CloudKit"]]))
		#expect(!CloudKitEntitlements.isEntitled(toContainer: container, entitlements: [key: [container], servicesKey: ["CloudDocuments"]]))
		#expect(!CloudKitEntitlements.isEntitled(toContainer: container, entitlements: [key: [container]]))
		#expect(!CloudKitEntitlements.isEntitled(toContainer: container, entitlements: [:]))
	}

	@Test func testRunnerIsNotEntitled() {
		#expect(!CloudKitEntitlements.isEntitled(toContainer: Self.containerIdentifier))
	}

	/// The disabled path: without the entitlement, sync is off and no `CKContainer` is made (which would trap).
	@Test func syncIsOffWithoutEntitlement() {
		let folderURL = temporaryFolderURL()
		let sync = TranscriptCloudSync(containerIdentifier: Self.containerIdentifier, store: TranscriptStore(folderURL: folderURL), stateFolderURL: folderURL) { _ in }
		#expect(sync == nil)
	}

	@Test func entitlementsAreReadFromThinExecutable() throws {
		let plist = try entitlementsPlist()
		let entitlements = try #require(CloudKitEntitlements.entitlements(fromExecutable: machOImage(entitlementsPlist: plist)))
		#expect(CloudKitEntitlements.isEntitled(toContainer: Self.containerIdentifier, entitlements: entitlements))
	}

	@Test func entitlementsAreReadFromUniversalExecutable() throws {
		let image = machOImage(entitlementsPlist: try entitlementsPlist())
		#if arch(arm64)
		let cpuType: UInt32 = 0x0100000c
		#else
		let cpuType: UInt32 = 0x01000007
		#endif
		let otherCPUType: UInt32 = 0x00000012
		let sliceOffset: UInt32 = 4096

		var data = Data()
		data.appendBigEndian(UInt32(0xcafebabe))
		data.appendBigEndian(UInt32(2))
		for (type, offset) in [(otherCPUType, UInt32(0)), (cpuType, sliceOffset)] {
			data.appendBigEndian(type)
			data.appendBigEndian(UInt32(0))
			data.appendBigEndian(offset)
			data.appendBigEndian(UInt32(image.count))
			data.appendBigEndian(UInt32(12))
		}
		data.append(Data(count: Int(sliceOffset) - data.count))
		data.append(image)

		let entitlements = try #require(CloudKitEntitlements.entitlements(fromExecutable: data))
		#expect(CloudKitEntitlements.isEntitled(toContainer: Self.containerIdentifier, entitlements: entitlements))
	}

	@Test func malformedExecutablesHaveNoEntitlements() throws {
		#expect(CloudKitEntitlements.entitlements(fromExecutable: Data()) == nil)
		#expect(CloudKitEntitlements.entitlements(fromExecutable: Data(repeating: 0xff, count: 64)) == nil)

		let image = machOImage(entitlementsPlist: try entitlementsPlist())
		for length in stride(from: 0, to: image.count, by: 7) {
			// Truncated anywhere: no crash, and no entitlements unless the whole blob is there.
			_ = CloudKitEntitlements.entitlements(fromExecutable: image.prefix(length))
		}
		#expect(CloudKitEntitlements.entitlements(fromExecutable: image.prefix(image.count - 1)) == nil)
	}

	func entitlementsPlist() throws -> Data {
		let entitlements: [String: Any] = [
			CloudKitEntitlements.containerIdentifiersKey: [Self.containerIdentifier],
			CloudKitEntitlements.servicesKey: ["CloudKit"]
		]
		return try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
	}

	/// A minimal 64-bit Mach-O image: a header, a segment command to skip, and a code signature
	/// with a code directory placeholder and an entitlements blob.
	func machOImage(entitlementsPlist: Data) -> Data {
		var data = Data()
		let headerSize = 32
		let segmentCommandSize: UInt32 = 72
		let codeSignatureCommandSize: UInt32 = 16
		let signatureOffset = UInt32(headerSize) + segmentCommandSize + codeSignatureCommandSize

		data.appendLittleEndian(UInt32(0xfeedfacf))
		data.appendLittleEndian(UInt32(0x0100000c))
		data.appendLittleEndian(UInt32(0))
		data.appendLittleEndian(UInt32(2))
		data.appendLittleEndian(UInt32(2))
		data.appendLittleEndian(segmentCommandSize + codeSignatureCommandSize)
		data.appendLittleEndian(UInt32(0))
		data.appendLittleEndian(UInt32(0))

		data.appendLittleEndian(UInt32(0x19))
		data.appendLittleEndian(segmentCommandSize)
		data.append(Data(count: Int(segmentCommandSize) - 8))

		data.appendLittleEndian(UInt32(0x1d))
		data.appendLittleEndian(codeSignatureCommandSize)
		data.appendLittleEndian(signatureOffset)
		data.appendLittleEndian(UInt32(0))

		let codeDirectory = Data([0xfa, 0xde, 0x0c, 0x02, 0, 0, 0, 8])
		var entitlementsBlob = Data()
		entitlementsBlob.appendBigEndian(UInt32(0xfade7171))
		entitlementsBlob.appendBigEndian(UInt32(8 + entitlementsPlist.count))
		entitlementsBlob.append(entitlementsPlist)

		let indexSize = 12 + 2 * 8
		data.appendBigEndian(UInt32(0xfade0cc0))
		data.appendBigEndian(UInt32(indexSize + codeDirectory.count + entitlementsBlob.count))
		data.appendBigEndian(UInt32(2))
		data.appendBigEndian(UInt32(0))
		data.appendBigEndian(UInt32(indexSize))
		data.appendBigEndian(UInt32(5))
		data.appendBigEndian(UInt32(indexSize + codeDirectory.count))
		data.append(codeDirectory)
		data.append(entitlementsBlob)

		return data
	}
}

private extension Data {

	mutating func appendBigEndian(_ value: UInt32) {
		Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
	}

	mutating func appendLittleEndian(_ value: UInt32) {
		Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
	}
}
