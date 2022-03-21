//
//  ProducersCommon.swift
//  Collected
//
//  Created by Patrick Smith on 21/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import SwiftUI
import Combine

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

//class LocalClock : ObservableObject {
//	@Published private(set) var counter = 0
//	
//	func tick() {
//		counter += 1
//	}
//}
