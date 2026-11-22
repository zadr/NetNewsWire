//
//  TranscriptCleanup.swift
//  Transcription
//

import Foundation

/// Decides which stored transcripts no longer belong to anything.
public enum TranscriptCleanup {

	/// Records whose account is gone, or whose feed is no longer in its account.
	/// `feedIDsByAccountID` has every existing account, including ones with no feeds.
	public static func recordsWithoutFeeds(_ records: [TranscriptRecord], feedIDsByAccountID: [String: Set<String>]) -> [TranscriptRecord] {
		records.filter { record in
			guard let feedIDs = feedIDsByAccountID[record.accountID] else {
				return true
			}
			return !feedIDs.contains(record.feedID)
		}
	}

	/// Records whose article is gone. `existingArticleIDsByAccountID` has, for each account,
	/// which of its records’ article IDs are still in its database.
	public static func recordsWithoutArticles(_ records: [TranscriptRecord], existingArticleIDsByAccountID: [String: Set<String>]) -> [TranscriptRecord] {
		records.filter { record in
			!(existingArticleIDsByAccountID[record.accountID]?.contains(record.articleID) ?? false)
		}
	}

	/// Article IDs of `records`, by account ID — for looking up which articles still exist.
	public static func articleIDsByAccountID(_ records: [TranscriptRecord]) -> [String: Set<String>] {
		records.reduce(into: [String: Set<String>]()) { articleIDsByAccountID, record in
			articleIDsByAccountID[record.accountID, default: []].insert(record.articleID)
		}
	}
}
