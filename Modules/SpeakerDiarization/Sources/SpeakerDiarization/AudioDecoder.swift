//
//  AudioDecoder.swift
//  SpeakerDiarization
//

import Foundation
import AVFoundation

/// Decodes an audio file to 16 kHz mono float samples, a block at a time.
enum AudioDecoder {

	static let sampleRate = LogMelExtractor.sampleRate
	private static let blockFrameCount: AVAudioFrameCount = 1 << 16

	/// Calls `handler` with each block of samples, in order.
	static func decode(fileURL: URL, handler: (UnsafeBufferPointer<Float>) throws -> Void) throws {
		let file: AVAudioFile
		do {
			file = try AVAudioFile(forReading: fileURL)
		} catch {
			throw SpeakerDiarizationError.unreadableAudio(error)
		}
		guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
			throw SpeakerDiarizationError.unreadableAudio(nil)
		}
		let inputFormat = file.processingFormat
		if inputFormat.sampleRate == sampleRate && inputFormat.channelCount == 1 && inputFormat.commonFormat == .pcmFormatFloat32 {
			try read(file, format: inputFormat, handler: handler)
		} else {
			try convert(file, to: outputFormat, handler: handler)
		}
	}
}

private extension AudioDecoder {

	static func read(_ file: AVAudioFile, format: AVAudioFormat, handler: (UnsafeBufferPointer<Float>) throws -> Void) throws {
		guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrameCount) else {
			throw SpeakerDiarizationError.unreadableAudio(nil)
		}
		while file.framePosition < file.length {
			do {
				try file.read(into: buffer)
			} catch {
				throw SpeakerDiarizationError.unreadableAudio(error)
			}
			guard buffer.frameLength > 0 else {
				return
			}
			try handle(buffer, handler: handler)
		}
	}

	static func convert(_ file: AVAudioFile, to outputFormat: AVAudioFormat, handler: (UnsafeBufferPointer<Float>) throws -> Void) throws {
		guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat),
			  let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: blockFrameCount) else {
			throw SpeakerDiarizationError.unreadableAudio(nil)
		}
		converter.downmix = true
		let input = ConverterInput(file: file, frameCapacity: blockFrameCount)

		while true {
			var conversionError: NSError?
			let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, inputStatus in
				input.next(packetCount: packetCount, status: inputStatus)
			}
			if let error = input.readError {
				throw SpeakerDiarizationError.unreadableAudio(error)
			}
			if status == .error {
				throw SpeakerDiarizationError.unreadableAudio(conversionError)
			}
			if outputBuffer.frameLength > 0 {
				try handle(outputBuffer, handler: handler)
			}
			if status == .endOfStream || (status == .inputRanDry && input.isAtEnd) {
				return
			}
		}
	}

	static func handle(_ buffer: AVAudioPCMBuffer, handler: (UnsafeBufferPointer<Float>) throws -> Void) throws {
		guard let channel = buffer.floatChannelData?[0] else {
			throw SpeakerDiarizationError.unreadableAudio(nil)
		}
		try handler(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
	}
}

/// Feeds an `AVAudioConverter` from an audio file. Only used synchronously, from within `convert(to:error:withInputFrom:)`.
private final class ConverterInput: @unchecked Sendable {

	private let file: AVAudioFile
	private let buffer: AVAudioPCMBuffer?
	private(set) var readError: Error?
	private(set) var isAtEnd = false

	init(file: AVAudioFile, frameCapacity: AVAudioFrameCount) {
		self.file = file
		self.buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCapacity)
	}

	func next(packetCount: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
		guard !isAtEnd, file.framePosition < file.length, let buffer else {
			isAtEnd = true
			status.pointee = .endOfStream
			return nil
		}
		do {
			try file.read(into: buffer, frameCount: min(packetCount, buffer.frameCapacity))
		} catch {
			readError = error
			isAtEnd = true
			status.pointee = .endOfStream
			return nil
		}
		guard buffer.frameLength > 0 else {
			isAtEnd = true
			status.pointee = .endOfStream
			return nil
		}
		status.pointee = .haveData
		return buffer
	}
}
