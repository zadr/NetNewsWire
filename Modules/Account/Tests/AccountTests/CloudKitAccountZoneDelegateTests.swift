//
//  CloudKitAccountZoneDelegateTests.swift
//  AccountTests
//

import CloudKit
import RSCore
import Testing
@testable import Account

@MainActor struct CloudKitAccountZoneDelegateTests {

	private let accountManager = TestAccountManager()
	private let zoneID = CKRecordZone.ID(zoneName: "Account", ownerName: CKCurrentUserDefaultName)

	@Test func topLevelFeedsFetchedBeforeTheAccountRecordAreAdded() async throws {
		let account = accountManager.createAccount(type: .onMyMac)
		defer {
			accountManager.deleteAccount(account)
		}
		let delegate = CloudKitAcountZoneDelegate(account: account, articlesZone: nil)

		// A new account doesn’t know its iCloud record yet, and the feed comes before it.
		try await delegate.cloudKitDidModify(changed: [feedRecord(url: "https://example.com/one.xml", containerExternalID: "account"), accountRecord(externalID: "account")], deleted: [])

		#expect(account.externalID == "account")
		#expect(account.topLevelFeeds.map { $0.url } == ["https://example.com/one.xml"])
	}

	@Test func topLevelFeedsFetchedAfterTheAccountRecordAreAdded() async throws {
		let account = accountManager.createAccount(type: .onMyMac)
		defer {
			accountManager.deleteAccount(account)
		}
		let delegate = CloudKitAcountZoneDelegate(account: account, articlesZone: nil)

		try await delegate.cloudKitDidModify(changed: [accountRecord(externalID: "account"), feedRecord(url: "https://example.com/one.xml", containerExternalID: "account")], deleted: [])

		#expect(account.topLevelFeeds.map { $0.url } == ["https://example.com/one.xml"])
	}

	@Test func anAccountRecordDoesNotReplaceTheAccountsOwn() async throws {
		let account = accountManager.createAccount(type: .onMyMac)
		defer {
			accountManager.deleteAccount(account)
		}
		account.externalID = "account"
		let delegate = CloudKitAcountZoneDelegate(account: account, articlesZone: nil)

		try await delegate.cloudKitDidModify(changed: [accountRecord(externalID: "other")], deleted: [])

		#expect(account.externalID == "account")
	}

	// MARK: - Helpers

	private func accountRecord(externalID: String) -> CKRecord {
		let record = CKRecord(recordType: CloudKitAccountZone.CloudKitContainer.recordType, recordID: CKRecord.ID(recordName: externalID, zoneID: zoneID))
		record[CloudKitAccountZone.CloudKitContainer.Fields.name] = "Account"
		record[CloudKitAccountZone.CloudKitContainer.Fields.isAccount] = "1"
		return record
	}

	private func feedRecord(url: String, containerExternalID: String) -> CKRecord {
		let record = CKRecord(recordType: CloudKitAccountZone.CloudKitFeed.recordType, recordID: CKRecord.ID(recordName: url.md5String, zoneID: zoneID))
		record[CloudKitAccountZone.CloudKitFeed.Fields.url] = url
		record[CloudKitAccountZone.CloudKitFeed.Fields.containerExternalIDs] = [containerExternalID]
		return record
	}
}
