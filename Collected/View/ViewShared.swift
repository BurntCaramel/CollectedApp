//
//  ProducersCommon.swift
//  Collected
//
//  Created by Patrick Smith on 21/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import SwiftUI
import WebKit
import PDFKit

func keyWindow() -> UIWindow? {
	guard let scene = UIApplication.shared.connectedScenes.first(where: {
		$0.activationState == .foregroundActive && $0 is UIWindowScene
	}) else {
		return nil
	}
	return (scene as? UIWindowScene)?.keyWindow
}

// See: https://stackoverflow.com/a/57877120/652615
func topMostViewController() -> UIViewController? {
	guard let rootController = keyWindow()?.rootViewController else {
		return nil
	}
	return topMostViewController(for: rootController)
}

private func topMostViewController(for controller: UIViewController) -> UIViewController {
	if let presentedController = controller.presentedViewController {
		return topMostViewController(for: presentedController)
	} else if let navigationController = controller as? UINavigationController {
		guard let topController = navigationController.topViewController else {
			return navigationController
		}
		return topMostViewController(for: topController)
	} else if let tabController = controller as? UITabBarController {
		guard let topController = tabController.selectedViewController else {
			return tabController
		}
		return topMostViewController(for: topController)
	}
	return controller
}

struct AsyncView<Value, Content: View>: View {
	let loader: @Sendable () async throws -> Value
	let content: (Result<Value, Error>?) -> Content
	@State var value: Result<Value, Error>?
	
	init(loader: @escaping @Sendable () async throws -> Value, @ViewBuilder content: @escaping (Result<Value, Error>?) -> Content) {
		self.loader = loader
		self.content = content
	}
	
	var body: some View {
		content(value)
			.task {
				do {
					self.value = .success(try await loader())
				}
				catch (let error) {
					self.value = .failure(error)
				}
			}
	}
}

struct AsyncObjectView<Value, Content: View>: View {
	@MainActor
	class AsyncState: ObservableObject {
		let loader: @Sendable () async throws -> Value
		
		@Published var value: Result<Value, Error>?
		
		init(loader: @escaping @Sendable () async throws -> Value) {
			self.loader = loader
		}
		
		func load() async {
			do {
				self.value = .success(try await loader())
			}
			catch (let error) {
				self.value = .failure(error)
			}
		}
	}
	
	let content: (Result<Value, Error>?) -> Content
	@StateObject var object: AsyncState
	
	init(loader: @escaping @Sendable () async throws -> Value, @ViewBuilder content: @escaping (Result<Value, Error>?) -> Content) {
		self.content = content
		self._object = StateObject(wrappedValue: AsyncState(loader: loader))
	}
	
	var body: some View {
		content(object.value)
			.task {
				await object.load()
			}
	}
}

struct ByteCountView: View {
	let byteCount: Int64
	@State private var showLong = false
	
	private static var shortFormatter = ByteCountFormatter()
	private static var longFormatter: ByteCountFormatter = {
		var f = ByteCountFormatter()
		f.allowedUnits = .useBytes
		return f
	}()
	
	var formatter: ByteCountFormatter {
		return showLong ? Self.longFormatter : Self.shortFormatter
	}
	
	var body: some View {
		Text(formatter.string(fromByteCount: byteCount))
			.onTapGesture { showLong.toggle() }
//			.onHover { showLong = $0 }
	}
}

struct WebView: UIViewRepresentable {
	var url: URL
	
	// Make a coordinator to co-ordinate with WKWebView's default delegate functions
//	func makeCoordinator() -> Coordinator {
//		Coordinator(self)
//	}
	
	func makeUIView(context: Context) -> WKWebView {
		// Enable javascript in WKWebView to interact with the web app
		let preferences = WKPreferences()
//		preferences.allowsContentJavaScript = true
		
		let configuration = WKWebViewConfiguration()
		// Here "iOSNative" is our interface name that we pushed to the website that is being loaded
//		configuration.userContentController.add(self.makeCoordinator(), name: "iOSNative")
		configuration.preferences = preferences
		
		let webView = WKWebView(frame: CGRect.zero, configuration: configuration)
//		webView.navigationDelegate = context.coordinator
		webView.allowsBackForwardNavigationGestures = true
		webView.scrollView.isScrollEnabled = true
		webView.scrollView.contentInset = .zero
	   return webView
	}
	
	func updateUIView(_ webView: WKWebView, context: Context) {
		webView.load(URLRequest(url: url))
	}
}

struct PDFView: UIViewRepresentable {
	var data: Data
	
	func makeUIView(context: Context) -> PDFKit.PDFView {
		return PDFKit.PDFView()
	}
	
	func updateUIView(_ view: PDFKit.PDFView, context: Context) {
		let document = PDFDocument(data: data)
		view.document = document
	}
}


//class LocalClock : ObservableObject {
//	@Published private(set) var counter = 0
//	
//	func tick() {
//		counter += 1
//	}
//}
