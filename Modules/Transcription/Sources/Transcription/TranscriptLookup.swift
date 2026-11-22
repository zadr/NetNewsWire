//
//  TranscriptLookup.swift
//  Transcription
//

import Foundation

/// When to look for an episode’s transcript in iCloud.
public enum TranscriptLookup {

	/// Transcribing first checks iCloud, in case another device already transcribed the episode.
	/// Re-transcribing doesn’t: iCloud would have the transcript being replaced.
	public static func checksICloudBeforeTranscribing(isRetranscribing: Bool, isSyncEnabled: Bool) -> Bool {
		isSyncEnabled && !isRetranscribing
	}

	/// An article with audio that’s shown, or whose commands are shown, is looked up in iCloud
	/// when it has no transcript here and isn’t being transcribed — so a transcript made on another device appears on its own.
	public static func looksUpWhenShown(hasLocalTranscript: Bool, isTranscribing: Bool, isSyncEnabled: Bool) -> Bool {
		isSyncEnabled && !hasLocalTranscript && !isTranscribing
	}
}

/// Coalesces lookups of the same episode and remembers misses for a while,
/// so showing many episodes (or the same one repeatedly) doesn’t make a request each time.
public struct TranscriptLookupThrottle: Sendable {

	public let missLifetime: TimeInterval

	private var inFlight = Set<EpisodeKey>()
	private var missDates = [EpisodeKey: Date]()

	public init(missLifetime: TimeInterval) {
		self.missLifetime = missLifetime
	}

	/// True when a lookup should start: none is in flight, and there was no recent miss. Marks it in flight.
	public mutating func begin(_ episodeKey: EpisodeKey, now: Date = Date()) -> Bool {
		guard !inFlight.contains(episodeKey) else {
			return false
		}
		if let missDate = missDates[episodeKey] {
			guard now.timeIntervalSince(missDate) >= missLifetime else {
				return false
			}
			missDates[episodeKey] = nil
		}
		inFlight.insert(episodeKey)
		return true
	}

	public func isInFlight(_ episodeKey: EpisodeKey) -> Bool {
		inFlight.contains(episodeKey)
	}

	public mutating func finish(_ episodeKey: EpisodeKey, found: Bool, now: Date = Date()) {
		inFlight.remove(episodeKey)
		if found {
			missDates[episodeKey] = nil
		} else {
			recordMiss(episodeKey, now: now)
		}
	}

	/// Such as after deleting the episode’s transcript, when iCloud may still have it until the deletion is sent.
	public mutating func recordMiss(_ episodeKey: EpisodeKey, now: Date = Date()) {
		missDates[episodeKey] = now
		missDates = missDates.filter { now.timeIntervalSince($0.value) < missLifetime }
	}

	/// Such as when iCloud reports a change to the episode.
	public mutating func forget(_ episodeKey: EpisodeKey) {
		missDates[episodeKey] = nil
	}
}
