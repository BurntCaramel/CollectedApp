//
//  FirstViewController.swift
//  Collected
//
//  Created by Patrick Smith on 8/9/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import UIKit
import SwiftUI
import Combine
import S3
import NIO

class FirstViewController: UIViewController {
	override func viewDidLoad() {
		super.viewDidLoad()
	}
}

class FirstHostingController: UIHostingController<StoresView> {
	var settings = Settings.Source()
	
	required init?(coder decoder: NSCoder) {
		super.init(coder: decoder, rootView: StoresView(settings: settings))
	}
}

class StoresSource: ObservableObject {
	private let s3: S3
	
	init(awsCredentials: Settings.AWSCredentials) {
		s3 = .init(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey, region: .uswest2)
//		s3 = .init(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey, region: .useast1)
	}
	
	enum Cache {
		enum Value {
			case bucketLocation(AnyPublisher<S3.BucketLocationConstraint?, Never>)
			case objects(AnyPublisher<[S3.Object], Never>)
			//case object(AnyPublisher<S3.GetObjectOutput, Never>)
			case object(Publishers.MakeConnectable<AnyPublisher<S3.GetObjectOutput, Never>>)
		}
		enum Key {
			case bucketLocation(bucket: String)
			case objects(forBucket: String)
			case object(bucketName: String, objectKey: String)
			
			var identifier: String {
				switch self {
				case let .bucketLocation(bucketName):
				return "bucketLocation(bucket: \(bucketName))"
				case let .objects(bucketName):
					return "objects(forBucket: \(bucketName))"
				case let .object(bucketName, objectKey):
					return "object(bucketName: \(bucketName), objectKey: \(objectKey))"
				}
			}
			
			func produceValue(s3: S3) -> Value {
				switch self {
				case let .bucketLocation(bucketName):
					return Value.bucketLocation(
						s3.getBucketLocation(.init(bucket: bucketName))
							.toCombine()
							.map({ $0.locationConstraint })
							.replaceError(with: nil)
							.receive(on: DispatchQueue.main)
							.eraseToAnyPublisher()
					)
				case let .objects(bucketName):
					return .objects(
						s3.listObjectsV2(.init(bucket: bucketName))
							.toCombine()
							.map({ $0.contents?.compactMap({ $0 }) ?? [] })
							.replaceError(with: [])
							.receive(on: DispatchQueue.main)
							.eraseToAnyPublisher()
					)
				case let .object(bucketName, objectKey):
					return .object(
						Deferred { () -> Combine.Future<S3.GetObjectOutput, Error> in
							print("Deferred STARTING!")
							let result = s3.getObject(.init(bucket: bucketName, key: objectKey))
								.toCombine()
							return result
						}
						.replaceError(with: .init())
						.receive(on: DispatchQueue.main)
						.print("OBJECT")
						.share()
						.eraseToAnyPublisher()
						.makeConnectable()
					)
				}
			}
			
			func read(cache: NSCache<NSString, Entry>, s3: S3) -> Value {
				let key = self.identifier as NSString
				if let entry = cache.object(forKey: key) {
					print("REUSING entry", key)
					return entry.value
				}
				
				let value = produceValue(s3: s3)
				let entry = Entry(value: value)
				print("CREATING entry", key)
				cache.setObject(entry, forKey: key)
				return value
			}
		}
		
		final class Entry {
			let value: Value
			
			init(value: Value) {
				self.value = value
			}
		}
	}
	
	private var cache = NSCache<NSString, Cache.Entry>()
	
	@Published var bucketsResult: Result<S3.ListBucketsOutput, Error>?
	
	var buckets: [S3.Bucket]? {
		switch bucketsResult {
		case .success(let output):
			return output.buckets
		default:
			return nil
		}
	}
	
	func load() {
		let s3 = self.s3
		s3.listBuckets().whenComplete { (result) in
			DispatchQueue.main.async {
				self.bucketsResult = result
			}
		}
	}
	
	//    func listBucket(bucketName: String) -> AnyPublisher<[S3.Object], Never> {
	//        let s3 = self.s3
	//        return Combine.Future { promise in
	//            s3.listObjectsV2(.init(bucket: bucketName)).map({ (output) in
	//                output.contents?.compactMap({ $0 }) ?? []
	//            }).whenComplete(promise)
	//        }
	//        .replaceError(with: .init())
	//        .receive(on: DispatchQueue.main)
	//        .eraseToAnyPublisher()
	//    }
	
	func loadBucketLocation(bucketName: String) -> AnyPublisher<S3.BucketLocationConstraint?, Never> {
		guard case let .bucketLocation(location) = Cache.Key.bucketLocation(bucket: bucketName).read(cache: cache, s3: s3) else {
			fatalError("Expected bucket location")
		}
		return location
	}
	
	func listBucket(bucketName: String) -> AnyPublisher<[S3.Object], Never> {
		guard case let .objects(publisher) = Cache.Key.objects(forBucket: bucketName).read(cache: cache, s3: s3) else {
			fatalError("Expected objects")
		}
		return publisher
	}
	
	func loadObject(bucketName: String, objectKey: String) -> Publishers.MakeConnectable<AnyPublisher<S3.GetObjectOutput, Never>> {
		guard case let .object(publisher) = Cache.Key.object(bucketName: bucketName, objectKey: objectKey).read(cache: cache, s3: s3) else {
			fatalError("Expected object")
		}
		return publisher
	}
}

struct StoresView: View {
	@ObservedObject var settings: Settings.Source
	//@ObservedObject var storesSource: StoresSource
	@State var storesSource: StoresSource?
	
	@ViewBuilder
	private var inner: some View {
		if let storesSource = self.storesSource {
			ListStoresView()
				.environmentObject(storesSource)
		} else {
			Text("Set ")
		}
	}
	
	var body: some View {
		VStack {
			if let storesSource = self.storesSource {
//				let storesSource = self.storesSource!
				ListStoresView()
					.environmentObject(storesSource)
			} else {
				Text("Set ")
			}
		}
		.onAppear { settings.load() }
		.onReceive(settings.$awsCredentials) { (awsCredentials) in
			storesSource = .init(awsCredentials: awsCredentials)
		}
	}
}

struct ListStoresView: View {
	@EnvironmentObject var storesSource: StoresSource
	
	var bucketNames: [String] {
		switch storesSource.buckets {
		case .some(let buckets):
			return buckets.compactMap({ $0.name })
		default:
			return []
		}
	}
	
	var body: some View {
		NavigationView {
			List {
				ForEach(bucketNames, id: \.self) { bucketName in
					NavigationLink(destination: BucketView(bucketName: bucketName)) {
						Text(bucketName)
					}
				}
			}
			.navigationBarTitle("Buckets")
		}
		.onAppear {
			self.storesSource.load()
		}
	}
}

struct BucketView: View {
	var bucketName: String
	
	@EnvironmentObject var storesSource: StoresSource
	@State var objects: [S3.Object]?
	
	enum MediaType: String {
		case textPlain = "text/plain"
		case textMarkdown = "text/markdown"
		case applicationJSON = "application/json"
	}
	
	struct NewState {
		var key = ""
		var mediaType = MediaType.textMarkdown
		var stringContent = ""
	}
	@State var newState = NewState()
	
	var newFormView: some View {
		Form {
			TextField("Key", text: self.$newState.key)
			Picker("Media Type", selection: self.$newState.mediaType) {
				Text("Plain text").tag(MediaType.textPlain)
				Text("Markdown").tag(MediaType.textMarkdown)
				Text("JSON").tag(MediaType.applicationJSON)
			}
			TextField("Content", text: self.$newState.stringContent)
			Button("Create") {
				//storesSource.createObject()
			}
		}
	}
	
	var body: some View {
		VStack {
			List {
				ForEach(objects ?? [], id: \.key) { object in
					NavigationLink(destination: ObjectInfoView(bucketName: self.bucketName, objectKey: object.key ?? "", object: object)) {
						Text(object.key ?? "")
					}
				}
			}
			newFormView
		}
		.navigationBarTitle(bucketName)
		.onReceive(storesSource.listBucket(bucketName: bucketName)) { (result) in
			if self.objects == nil {
				self.objects = result
			}
		}
	}
}

struct ObjectInfoView: View {
	var bucketName: String
	var objectKey: String
	var object: S3.Object
	
	@EnvironmentObject var storesSource: StoresSource
	@State var output: S3.GetObjectOutput?
	@State var cancellables = Set<AnyCancellable>()
	
	var objectPublisher: Publishers.MakeConnectable<AnyPublisher<S3.GetObjectOutput, Never>> {
		storesSource.loadObject(bucketName: bucketName, objectKey: objectKey)
	}
	
	var previewView: some View {
		if let output = self.output, let mediaType = output.contentType, let contentData = output.body {
			return AnyView(
				VStack {
					ContentPreview.PreviewView(mediaType: mediaType, contentData: contentData)
				}
			)
		} else {
			return AnyView(Text("HAS NO PREVIEW"))
		}
	}
	
	var body: some View {
		return VStack {
			Text(objectKey)
			Text("Size: \(object.size ?? 0)")
			Text("Content type: \(output?.contentType ?? "")")
			Text("Content bytes: \(output?.body?.count ?? 0)")
			Button(action: load) { Text("Load") }
			
			VStack {
				Text("preview!")
				self.previewView
			}
		}
		.navigationBarTitle("\(objectKey)", displayMode: .inline)
		.onAppear(perform: load)
		.onReceive(objectPublisher) { (output) in
			if output.eTag != self.output?.eTag {
				self.output = output
			}
		}
	}
	
	func load() {
		objectPublisher.connect().store(in: &cancellables)
	}
}
