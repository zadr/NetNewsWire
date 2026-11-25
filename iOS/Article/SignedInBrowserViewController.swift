//
//  SignedInBrowserViewController.swift
//  NetNewsWire-iOS
//

import UIKit
import WebKit
import SafariServices
import Account

/// The in-app browser for sites signed in to with `SiteCookies`.
///
/// Safari View Controller keeps its own cookies, so it can’t be signed in;
/// this browser starts with the site’s stored cookies instead. Its data store is
/// non-persistent, so whatever happens while browsing is forgotten when it closes.
@MainActor final class SignedInBrowserViewController: UIViewController {

	private let url: URL
	private let webView: WKWebView
	private var observations = [NSKeyValueObservation]()
	private var didFinish: (() -> Void)?

	private lazy var backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), primaryAction: UIAction { [weak self] _ in
		self?.webView.goBack()
	})
	private lazy var forwardItem = UIBarButtonItem(image: UIImage(systemName: "chevron.forward"), primaryAction: UIAction { [weak self] _ in
		self?.webView.goForward()
	})
	private lazy var shareItem = UIBarButtonItem(systemItem: .action, primaryAction: UIAction { [weak self] _ in
		self?.share()
	})

	/// A browser for `url`, signed in if `SiteCookies` has cookies for its site, otherwise Safari View Controller.
	/// `didFinish` is called when it’s dismissed.
	static func browser(for url: URL, didFinish: (() -> Void)? = nil) -> UIViewController? {
		guard SiteCookies.shared.isSignedIn(to: url) else {
			return SFSafariViewController.safeSafariViewController(url)
		}
		let controller = SignedInBrowserViewController(url: url, didFinish: didFinish)
		let navigationController = UINavigationController(rootViewController: controller)
		navigationController.isToolbarHidden = false
		navigationController.modalPresentationStyle = .fullScreen
		return navigationController
	}

	private init(url: URL, didFinish: (() -> Void)?) {
		self.url = url
		self.didFinish = didFinish

		let configuration = WKWebViewConfiguration()
		configuration.websiteDataStore = .nonPersistent()
		webView = WKWebView(frame: .zero, configuration: configuration)

		super.init(nibName: nil, bundle: nil)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		view = webView
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
			self?.dismiss(animated: true)
		})
		navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .refresh, primaryAction: UIAction { [weak self] _ in
			self?.webView.reload()
		})

		let openInSafariItem = UIBarButtonItem(image: UIImage(systemName: "safari"), primaryAction: UIAction { [weak self] _ in
			self?.openInSafari()
		})
		toolbarItems = [backItem, .flexibleSpace(), forwardItem, .flexibleSpace(), shareItem, .flexibleSpace(), openInSafariItem]

		webView.navigationDelegate = self
		webView.allowsBackForwardNavigationGestures = true
		observations = [
			webView.observe(\.canGoBack, options: [.initial]) { [weak self] webView, _ in
				MainActor.assumeIsolated {
					self?.backItem.isEnabled = webView.canGoBack
				}
			},
			webView.observe(\.canGoForward, options: [.initial]) { [weak self] webView, _ in
				MainActor.assumeIsolated {
					self?.forwardItem.isEnabled = webView.canGoForward
				}
			},
			webView.observe(\.url, options: [.initial]) { [weak self] webView, _ in
				MainActor.assumeIsolated {
					self?.navigationItem.title = (webView.url ?? self?.url)?.host()
				}
			}
		]

		Task {
			let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
			for cookie in SiteCookies.shared.cookies(for: url) {
				await cookieStore.setCookie(cookie)
			}
			webView.load(URLRequest(url: url))
		}
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)
		if navigationController?.isBeingDismissed ?? isBeingDismissed {
			didFinish?()
			didFinish = nil
		}
	}
}

// MARK: - WKNavigationDelegate

extension SignedInBrowserViewController: WKNavigationDelegate {

	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
		// Links that open new windows (target=_blank) would otherwise do nothing.
		if navigationAction.targetFrame == nil {
			webView.load(navigationAction.request)
			return .cancel
		}
		return .allow
	}
}

// MARK: - Private

private extension SignedInBrowserViewController {

	var currentURL: URL {
		webView.url ?? url
	}

	func share() {
		let activityViewController = UIActivityViewController(activityItems: [currentURL], applicationActivities: nil)
		activityViewController.popoverPresentationController?.barButtonItem = shareItem
		present(activityViewController, animated: true)
	}

	func openInSafari() {
		UIApplication.shared.open(currentURL, options: [:])
	}
}
