//
//  ContentRepo.swift
//  Collected
//
//  Created by Patrick Smith on 20/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import Foundation
import Combine
import SotoS3
import NIO
import CryptoKit
import SwiftUI

@propertyWrapper
class LocalClock : ObservableObject {
	@Published private(set) var counter = 0
	
	func tick() {
		counter += 1
	}
	
	var wrappedValue: LocalClock {
		self
	}
	
	var projectedValue: Published<Int>.Publisher {
		self.$counter
	}
}

class StoresSource: ObservableObject {
	private let awsClient: AWSClient
	private let s3: S3
	
	init(awsCredentials: Settings.AWSCredentials) {
		awsClient = AWSClient(credentialProvider: .static(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey), httpClientProvider: .createNew)
		//let awsClient = AWSClient(credentialProvider: .static(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey))
		s3 = S3(client: awsClient, region: .useast1)
		//s3 = .init(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey, region: .uswest2)
		//		s3 = .init(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey, region: .useast1)
	}
	
	func s3(region: Region) -> S3 {
		return S3(client: awsClient, region: region)
	}
	
	func listS3Buckets() async throws -> [S3.Bucket] {
		try await s3.listBuckets().buckets ?? []
	}
	
	func shutdown() {
		try? awsClient.syncShutdown()
	}
}

class BucketSource : ObservableObject {
	let bucketName: String
//	private let s3: S3
	
	var collectedPressRootURL: URL? {
		URL(string: "https://collected.press/1/s3/object/\(producers.s3.region.rawValue)/\(bucketName)/")
	}
	
	fileprivate struct Producers {
		let bucketName: String
		let s3: S3
		
		init(bucketName: String, s3: S3) {
			self.bucketName = bucketName
			self.s3 = s3
		}
		
		fileprivate init(bucketName: String, awsClient: AWSClient) async throws {
			let s3Global = S3(client: awsClient)
			let location = try await s3Global.getBucketLocation(.init(bucket: bucketName, expectedBucketOwner: nil))
			let locationConstraint = location.locationConstraint!
			let region = Region(awsRegionName: locationConstraint.rawValue)
			let s3 = S3(client: awsClient, region: region)
			
			self.init(bucketName: bucketName, s3: s3)
		}
		
		struct ListFilter {
			enum ContentType {
				case all
				case texts
				case images
				case pdfs
				
				var prefix: String? {
					switch self {
					case .all:
						return nil
					case .texts:
						return "sha256/text/"
					case .images:
						return "sha256/image/"
					case .pdfs:
						return "sha256/application/pdf/"
					}
				}
			}
			var contentType: ContentType
		}
		
		private func list(filter: ListFilter) -> AnyPublisher<[S3.Object], Never> {
			return Deferred { s3.listObjectsV2(.init(bucket: bucketName, prefix: filter.contentType.prefix)) }
			.map({ $0.contents?.compactMap({ $0 }) ?? [] })
			.replaceError(with: [])
			.receive(on: DispatchQueue.main)
			.eraseToAnyPublisher()
		}
		
		func list<P : Publisher>(clock: P, filter: ListFilter) -> AnyPublisher<[S3.Object], Never> where P.Failure == Never {
			return clock
				.map { _ in list(filter: filter) }
				.switchToLatest()
				.eraseToAnyPublisher()
		}
		
		func region() async throws -> S3.BucketLocationConstraint? {
			let location = try await s3.getBucketLocation(.init(bucket: bucketName, expectedBucketOwner: nil))
			return location.locationConstraint
		}
		
		func list(region: Region, filter: ListFilter) async throws -> [S3.Object] {
			let s3 = S3(client: self.s3.client, region: region)
			let objects = try await s3.listObjectsV2(.init(bucket: bucketName, prefix: filter.contentType.prefix))
			return objects.contents ?? []
		}
		
		func getObject(key: String) async throws -> S3.GetObjectOutput {
			return try await s3.getObject(.init(bucket: bucketName, key: key))
		}
		
		func createPublicReadable(content: ContentResource) -> AnyPublisher<S3.PutObjectOutput, Error> {
			let contentID = content.id
			let key = contentID.objectStorageKey
			
			let request = S3.PutObjectRequest(acl: .publicRead, body: AWSPayload.data(content.data), bucket: bucketName, contentType: contentID.mediaType.string, key: key)
			return Deferred { s3.putObject(request) }
			.print()
			.receive(on: DispatchQueue.main)
			.eraseToAnyPublisher()
		}
		
		func makePublicReadable(contentID: ContentIdentifier) -> AnyPublisher<S3.PutObjectAclOutput, Error> {
			let key = contentID.objectStorageKey
			return makePublicReadable(key: key)
		}
		
		func makePublicReadable(key: String) -> AnyPublisher<S3.PutObjectAclOutput, Error> {
			let request = S3.PutObjectAclRequest(acl: .publicRead, bucket: bucketName, key: key)
			return Deferred { s3.putObjectAcl(request) }
			.receive(on: DispatchQueue.main)
			.eraseToAnyPublisher()
		}
		
		func delete(key: String) -> AnyPublisher<S3.DeleteObjectOutput, Error> {
			return Deferred { s3.deleteObject(.init(bucket: bucketName, key: key)) }
			.print()
			.receive(on: DispatchQueue.main)
			.eraseToAnyPublisher()
		}
	}
	fileprivate let producers: Producers
	
	fileprivate init(bucketName: String, s3: S3) {
		self.bucketName = bucketName
		self.producers = .init(bucketName: bucketName, s3: s3)
	}
	
	fileprivate init(bucketName: String, awsClient: AWSClient) async throws {
		self.bucketName = bucketName
		self.producers = try await .init(bucketName: bucketName, awsClient: awsClient)
	}
	
	@Published var objects: [S3.Object]?
	let loadClock = LocalClock()
	private lazy var listCancellable = producers.list(clock: loadClock.$counter, filter: .init(contentType: .all))
		.print("LOADING ALL!")
		.sink { self.objects = $0 }
	
	func load() {
		loadClock.tick()
		_ = listCancellable
	}
	
	func listAll(region: Region) async throws -> [S3.Object] {
		try await producers.list(region: region, filter: .init(contentType: .all))
	}
	
	@Published var textObjects: [S3.Object]?
	@LocalClock var loadTextsClock
	//	let loadTextsClock = LocalClock()
	private lazy var listTextsCancellable = producers.list(clock: $loadTextsClock, filter: .init(contentType: .texts))
		.print("LOADING TEXTS!")
		.sink { self.textObjects = $0 }
	
	func loadTexts() {
		loadTextsClock.tick()
		_ = listTextsCancellable
	}
	
	@Published var imageObjects: [S3.Object]?
	@LocalClock var loadImagesClock
	private lazy var listImagesCancellable = producers.list(clock: $loadImagesClock, filter: .init(contentType: .images))
		.print("LOADING IMAGES!")
		.sink { self.imageObjects = $0 }
	func loadImages() {
		loadImagesClock.tick()
		_ = listImagesCancellable
	}
	
	@Published var pdfObjects: [S3.Object]?
	@LocalClock var loadPDFsClock
	private lazy var listPDFsCancellable = producers.list(clock: $loadPDFsClock, filter: .init(contentType: .pdfs))
		.print("LOADING PDFS!")
		.sink { self.pdfObjects = $0 }
	func loadPDFs() {
		loadPDFsClock.tick()
		_ = listPDFsCancellable
	}
	
	var createCancellables = Set<AnyCancellable>()
	var changeCancellables = Set<AnyCancellable>()
	var deleteCancellables = Set<AnyCancellable>()
	
	func region() async throws -> S3.BucketLocationConstraint? {
		try await producers.region()
	}
	
	func getObject(key: String) async throws -> S3.GetObjectOutput {
		try await producers.getObject(key: key)
	}
	
	func createPublicReadable(content: ContentResource) {
		producers.createPublicReadable(content: content)
			.sink { [self] completion in
				switch completion {
				case .finished:
					self.load()
				case let .failure(error):
					print("Error creating", error)
				}
			} receiveValue: { _ in }
			.store(in: &createCancellables)
	}
	
	func makePublicReadable(key: String) {
		producers.makePublicReadable(key: key)
			.sink { [self] completion in
				switch completion {
				case .finished:
					self.load()
				case let .failure(error):
					print("Error make public read", error)
				}
			} receiveValue: { _ in }
			.store(in: &changeCancellables)
	}
	
	func delete(key: String) {
		producers.delete(key: key)
			.sink { [self] completion in
				switch completion {
				case .finished:
					self.load()
				case let .failure(error):
					print("ERror deleting", error)
				}
			} receiveValue: { _ in }
			.store(in: &deleteCancellables)
	}
	
	class ObjectSource: ObservableObject {
		private let bucketSource: BucketSource
		let key: String
		
		fileprivate init(bucketSource: BucketSource, key: String) {
			self.bucketSource = bucketSource
			self.key = key
		}
		
		private var cancellables = Set<AnyCancellable>()
		@Published private var getObjectOutput: S3.GetObjectOutput?
		@Published private var getACLOutput: S3.GetObjectAclOutput?
		
		var data: Data? {
			getObjectOutput?.body?.asData()
		}
		
		var isPublicReadable: Bool? {
			nil
		}
		
		private lazy var getDataProducer = bucketSource.producers.s3
			.getObject(.init(bucket: bucketSource.bucketName, key: key))
			.toCombine()
			.receive(on: DispatchQueue.main)
		
		private lazy var getACLProducer = bucketSource.producers.s3
			.getObjectAcl(.init(bucket: bucketSource.bucketName, key: key))
			.toCombine()
			.receive(on: DispatchQueue.main)
		
		func load() {
			getDataProducer.sink { (completion) in
				print("COMPLETED", completion)
			} receiveValue: { (output) in
				self.getObjectOutput = output
			}
			.store(in: &cancellables)
			
			getACLProducer.sink { (completion) in
				
			} receiveValue: { (output) in
				self.getACLOutput = output
			}
			.store(in: &cancellables)
		}
	}
	
	func object(key: String) -> ObjectSource { ObjectSource(bucketSource: self, key: key) }
}

extension StoresSource {
//	func bucket(name: String) -> BucketSource { BucketSource(bucketName: name, s3: s3) }
	
	func bucketInCorrectedRegion(name: String) async throws -> BucketSource { try await BucketSource(bucketName: name, awsClient: s3.client) }
}

@MainActor
class S3ObjectSource : ObservableObject {
	private struct Producers {
		let s3: S3
		let bucketName: String
		let objectKey: String
		
		func get() -> AnyPublisher<S3.GetObjectOutput, Error> {
			return Deferred { s3.getObject(.init(bucket: bucketName, key: objectKey)) }
			.receive(on: DispatchQueue.main)
			.eraseToAnyPublisher()
		}
	}
	private let producers: Producers
	
	init(bucketName: String, objectKey: String, s3: S3) {
		self.producers = .init(s3: s3, bucketName: bucketName, objectKey: objectKey)
	}
	
	var objectKey: String { producers.objectKey }
	
	var collectedPressURL: URL? {
		URL(string: "https://collected.press/1/s3/object/\(producers.s3.region.rawValue)/\(producers.bucketName)/\(producers.objectKey)")
	}
	
	@Published var getResult: Result<S3.GetObjectOutput, Error>?
	
	private lazy var getCancellable = producers.get()
		.catchAsResult()
		.sink { self.getResult = $0 }
	
	func load() {
		_ = getCancellable
	}
}

extension BucketSource {
	@MainActor func useObject(key: String) -> S3ObjectSource { S3ObjectSource(bucketName: bucketName, objectKey: key, s3: producers.s3) }
}
