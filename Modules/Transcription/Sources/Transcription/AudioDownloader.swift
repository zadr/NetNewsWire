//
//  AudioDownloader.swift
//  Transcription
//

import Foundation
import CryptoKit
import Synchronization

/// Downloads audio to a cache folder, so it can be read as a file.
/// A file that’s already there is used instead of downloading it again.
public struct AudioDownloader: Sendable {

	public let cacheFolderURL: URL

	public init(cacheFolderURL: URL) {
		self.cacheFolderURL = cacheFolderURL
	}

	/// `progressHandler` gets the fraction downloaded, or nil when the size isn’t known.
	@concurrent public func download(_ url: URL, progressHandler: @escaping @Sendable (Double?) -> Void) async throws -> URL {
		let fileURL = cachedFileURL(for: url)
		if FileManager.default.fileExists(atPath: fileURL.path) {
			return fileURL
		}

		try FileManager.default.createDirectory(at: cacheFolderURL, withIntermediateDirectories: true)

		let delegate = AudioDownloadDelegate(progressHandler: progressHandler)
		let (temporaryURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
		if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
			try? FileManager.default.removeItem(at: temporaryURL)
			throw TranscriptionError.downloadFailed(statusCode: httpResponse.statusCode)
		}

		try? FileManager.default.removeItem(at: fileURL)
		try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
		return fileURL
	}

	public func removeCachedFile(for url: URL) {
		try? FileManager.default.removeItem(at: cachedFileURL(for: url))
	}

	/// Removes cached audio last changed before `date`, except the audio for `urlsInUse`.
	/// Audio is left behind when transcription fails or is canceled, for trying again.
	/// Returns the number of files removed.
	@discardableResult
	public func removeCachedFiles(changedBefore date: Date, except urlsInUse: Set<URL> = []) -> Int {
		let fileNamesInUse = Set(urlsInUse.map { cachedFileURL(for: $0).lastPathComponent })
		let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
		guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: cacheFolderURL, includingPropertiesForKeys: keys) else {
			return 0
		}

		var removedCount = 0
		for fileURL in fileURLs where !fileNamesInUse.contains(fileURL.lastPathComponent) {
			guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)), resourceValues.isRegularFile == true else {
				continue
			}
			if let modificationDate = resourceValues.contentModificationDate, modificationDate >= date {
				continue
			}
			if (try? FileManager.default.removeItem(at: fileURL)) != nil {
				removedCount += 1
			}
		}
		return removedCount
	}

	/// A hash of the URL, plus its extension, which AVFoundation uses to recognize the format.
	public func cachedFileURL(for url: URL) -> URL {
		var fileName = SHA256.hash(data: Data(url.absoluteString.utf8)).hexString
		let pathExtension = url.pathExtension.lowercased()
		if !pathExtension.isEmpty, pathExtension.count <= 5 {
			fileName += "." + pathExtension
		}
		return cacheFolderURL.appendingPathComponent(fileName, isDirectory: false)
	}
}

/// The async download API doesn’t call `didWriteData` on task delegates, so this watches the task’s `progress` instead.
/// Reports only when the whole percent changes, since `fractionCompleted` changes far more often than that.
private final class AudioDownloadDelegate: NSObject, URLSessionTaskDelegate, Sendable {

	private struct State {
		var observation: NSKeyValueObservation?
		var lastPercent: Int?
	}

	private let progressHandler: @Sendable (Double?) -> Void
	private let state = Mutex(State())

	init(progressHandler: @escaping @Sendable (Double?) -> Void) {
		self.progressHandler = progressHandler
	}

	deinit {
		state.withLock { $0.observation?.invalidate() }
	}

	func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
		let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
			self?.progressDidChange(progress)
		}
		state.withLock { $0.observation = observation }
	}

	private func progressDidChange(_ progress: Progress) {
		guard progress.totalUnitCount > 0 else {
			return
		}
		let fractionCompleted = min(1, max(0, progress.fractionCompleted))
		let percent = Int(fractionCompleted * 100)
		let shouldReport = state.withLock { state in
			guard state.lastPercent != percent else {
				return false
			}
			state.lastPercent = percent
			return true
		}
		if shouldReport {
			progressHandler(fractionCompleted)
		}
	}
}
