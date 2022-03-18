//
//  ProducersCommon.swift
//  Collected
//
//  Created by Patrick Smith on 21/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import SwiftUI
import Combine

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
