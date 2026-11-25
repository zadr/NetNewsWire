//
//  PictureInPictureKeeper.swift
//  NetNewsWire
//
//  Created by Zach Drayer on 11/25/26.
//  Copyright © 2026 Ranchero Software. All rights reserved.
//

import Foundation
import WebKit
import os

/// Keeps a video playing when its article goes away, by moving it into picture in picture
/// and keeping its web view alive until picture in picture ends.
@MainActor final class PictureInPictureKeeper: NSObject {

	static let shared = PictureInPictureKeeper()

	private static let logger = Logger(subsystem: Logger.nnwSubsystem, category: "PictureInPictureKeeper")
	private static let messageName = "videoStateDidChange"

	/// A separate world, so tracking works whether or not content JavaScript is on.
	private static let contentWorld = WKContentWorld.world(name: "PictureInPicture")

	/// How long to wait for a video to enter picture in picture before stopping it.
	private static let enterTimeout: Duration = .seconds(3)

	/// The frame of each web view that's playing a video. Videos in embeds like YouTube's are in a subframe.
	private let playingFrames = NSMapTable<WKWebView, WKFrameInfo>.weakToStrongObjects()

	/// Web views kept alive for their video, and whether it has entered picture in picture.
	private var keptWebViews = [ObjectIdentifier: (webView: WKWebView, isInPictureInPicture: Bool)]()

	func addUserScript(to userContentController: WKUserContentController) {
		userContentController.addUserScript(WKUserScript(source: Self.videoStateScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.contentWorld))
		userContentController.add(self, contentWorld: Self.contentWorld, name: Self.messageName)
	}

	/// Moves the web view's playing video into picture in picture and takes over the web view.
	/// Returns false, leaving the web view with the caller, when there's no playing video.
	func keepPlaying(_ webView: WKWebView) -> Bool {
		guard let frame = playingFrames.object(forKey: webView), webView.fullscreenState == .notInFullscreen else {
			return false
		}
		playingFrames.removeObject(forKey: webView)

		let identifier = ObjectIdentifier(webView)
		keptWebViews[identifier] = (webView, false)
		park(webView)

		webView.callAsyncJavaScript(Self.enterPictureInPictureScript, arguments: [:], in: frame, in: Self.contentWorld) { [weak self] result in
			if case .failure(let error) = result {
				Self.logger.info("PictureInPictureKeeper: couldn't enter picture in picture: \(error.localizedDescription)")
				self?.release(webView)
			}
		}

		Task { [weak self] in
			try? await Task.sleep(for: Self.enterTimeout)
			guard let self, let kept = keptWebViews[identifier], !kept.isInPictureInPicture else {
				return
			}
			Self.logger.info("PictureInPictureKeeper: video didn't enter picture in picture")
			release(kept.webView)
		}

		return true
	}
}

// MARK: - WKScriptMessageHandler

extension PictureInPictureKeeper: WKScriptMessageHandler {

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		guard let webView = message.webView, let body = message.body as? [String: Bool] else {
			return
		}
		let isPlaying = body["isPlaying"] ?? false
		let isInPictureInPicture = body["isInPictureInPicture"] ?? false

		let identifier = ObjectIdentifier(webView)
		if let kept = keptWebViews[identifier] {
			if isInPictureInPicture {
				keptWebViews[identifier] = (webView, true)
			} else if kept.isInPictureInPicture {
				// Closed, or sent back to an article that's gone.
				release(webView)
			}
			return
		}

		if isPlaying {
			playingFrames.setObject(message.frameInfo, forKey: webView)
		} else if let playingFrame = playingFrames.object(forKey: webView), Self.isSameFrame(playingFrame, message.frameInfo) {
			playingFrames.removeObject(forKey: webView)
		}
	}
}

// MARK: - Private

private extension PictureInPictureKeeper {

	/// Takes the web view out of the article. On iOS a video in a web view outside a window
	/// stops playing, so it stays in the window, out of sight.
	func park(_ webView: WKWebView) {
		webView.navigationDelegate = nil
		webView.uiDelegate = nil
		webView.configuration.userContentController.removeAllScriptMessageHandlers(from: .page)
#if os(iOS)
		let window = webView.window
		webView.removeFromSuperview()
		webView.scrollView.delegate = nil
		if let window {
			webView.translatesAutoresizingMaskIntoConstraints = true
			webView.frame = window.bounds.offsetBy(dx: window.bounds.width * 2, dy: 0)
			webView.isUserInteractionEnabled = false
			window.insertSubview(webView, at: 0)
		}
#else
		webView.removeFromSuperview()
#endif
	}

	func release(_ webView: WKWebView) {
		guard keptWebViews.removeValue(forKey: ObjectIdentifier(webView)) != nil else {
			return
		}
		webView.pauseAllMediaPlayback {
			webView.removeFromSuperview()
		}
	}

	/// Frame infos are snapshots, so a frame's messages each come with a different one.
	static func isSameFrame(_ frame: WKFrameInfo, _ otherFrame: WKFrameInfo) -> Bool {
		frame.isMainFrame == otherFrame.isMainFrame && frame.request.url == otherFrame.request.url
	}

	static let videoStateScript = """
	(() => {
		const postVideoState = () => {
			const videos = Array.from(document.querySelectorAll("video"));
			window.webkit.messageHandlers.\(messageName).postMessage({
				isPlaying: videos.some(video => !video.paused && !video.ended),
				isInPictureInPicture: videos.some(video => video.webkitPresentationMode === "picture-in-picture")
			});
		};
		// Media events don't bubble, so listen for them on the way down.
		for (const name of ["play", "pause", "ended", "emptied", "webkitpresentationmodechanged"]) {
			document.addEventListener(name, postVideoState, true);
		}
	})();
	"""

	static let enterPictureInPictureScript = """
	const video = Array.from(document.querySelectorAll("video")).find(video => !video.paused && !video.ended);
	if (!video) {
		throw new Error("No playing video");
	}
	if (video.requestPictureInPicture) {
		await video.requestPictureInPicture();
	} else {
		video.webkitSetPresentationMode("picture-in-picture");
	}
	"""
}
