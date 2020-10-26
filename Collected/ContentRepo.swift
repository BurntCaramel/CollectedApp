//
//  ContentRepo.swift
//  Collected
//
//  Created by Patrick Smith on 20/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import Foundation
import Combine
import S3
import NIO
import CryptoKit

class LocalClock : ObservableObject {
	@Published private(set) var counter = 0
	
	func tick() {
		counter += 1
	}
}

class StoresSource: ObservableObject {
	private let s3: S3
	
	init(awsCredentials: Settings.AWSCredentials) {
		s3 = .init(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey, region: .uswest2)
		//		s3 = .init(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey, region: .useast1)
	}
}

class S3Source : ObservableObject {
	fileprivate struct Producers {
		let s3: S3
		
		init(s3: S3) {
			self.s3 = s3
		}
		
		private func listBuckets() -> AnyPublisher<[S3.Bucket], Error> {
			return Deferred { s3.listBuckets() }
				.map({ $0.buckets?.compactMap({ $0 }) ?? [] })
				.receive(on: DispatchQueue.main)
				.eraseToAnyPublisher()
		}
		
		func listBuckets<P : Publisher>(clock: P) -> AnyPublisher<Result<[S3.Bucket], Error>, Never> where P.Failure == Never {
			return clock
				.map { _ in listBuckets().catchAsResult() }
				.switchToLatest()
				.eraseToAnyPublisher()
		}
	}
	private let producers: Producers
	
	fileprivate init(s3: S3) {
		self.producers = .init(s3: s3)
	}
	
	let loadClock = LocalClock()
	@Published var bucketsResult: Result<[S3.Bucket], Error>?
	
	private lazy var listBucketsCancellable = producers.listBuckets(clock: loadClock.$counter)
		.sink { self.bucketsResult = $0 }

	func load() {
		loadClock.tick()
		_ = listBucketsCancellable
	}
}

extension StoresSource {
	func useBuckets() -> S3Source { .init(s3: s3) }
}

class BucketSource : ObservableObject {
	let bucketName: String
	private let s3: S3
	
	fileprivate struct Producers {
		let bucketName: String
		let s3: S3
		
		init(bucketName: String, s3: S3) {
			self.bucketName = bucketName
			self.s3 = s3
		}
		
//		fileprivate lazy var listProducer = Deferred { s3.listObjectsV2(.init(bucket: bucketName)) }
//			.map({ $0.contents?.compactMap({ $0 }) ?? [] })
//			.replaceError(with: [])
//			.receive(on: DispatchQueue.main)
//			.eraseToAnyPublisher()
		
		func list() -> AnyPublisher<[S3.Object], Never> {
			return Deferred { s3.listObjectsV2(.init(bucket: bucketName)) }
			.map({ $0.contents?.compactMap({ $0 }) ?? [] })
			.replaceError(with: [])
			.receive(on: DispatchQueue.main)
			.eraseToAnyPublisher()
		}
		
		func list<P : Publisher>(clock: P) -> AnyPublisher<[S3.Object], Never> where P.Failure == Never {
			return clock
				.map { _ in list() }
				.switchToLatest()
				.eraseToAnyPublisher()
		}
		
		func create(content: ContentResource) -> AnyPublisher<S3.PutObjectOutput, Error> {
			let contentID = content.id
			let key = contentID.objectStorageKey
			print("PUT OBJECT: KEY", key)
			
			let request = S3.PutObjectRequest(body: content.data, bucket: bucketName, contentType: contentID.mediaType.string, key: key)
			return Deferred { s3.putObject(request) }
				.print()
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
		self.s3 = s3
		
		self.producers = .init(bucketName: bucketName, s3: s3)
	}
	
	@Published var objects: [S3.Object]?
	
	let loadClock = LocalClock()
	
	private lazy var listCancellable = producers.list(clock: loadClock.$counter)
		.print("LOADING!")
		.sink { self.objects = $0 }
	
	var createCancellables = Set<AnyCancellable>()
	var deleteCancellables = Set<AnyCancellable>()
	
	func load() {
		loadClock.tick()
		_ = listCancellable
		
		//		_ = self.listCancellable
		//		print("RELOADING list bucket")
		//		listCancellables.removeAll()
		//
		//		listProducer
		//			.sink { self.objects = $0 }
		//			.store(in: &listCancellables)
	}
	
	func create(content: ContentResource) {
		producers.create(content: content)
			.sink { [self] completion in
				switch completion {
				case .finished:
					self.load()
				case let .failure(error):
					print("ERror creating", error)
				}
			} receiveValue: { _ in }
			.store(in: &createCancellables)
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
		
		private var cancellable: AnyCancellable?
		@Published private var getObjectOutput: S3.GetObjectOutput?
		
		var data: Data? {
			getObjectOutput?.body
		}
		
		private lazy var producer = bucketSource.s3
			.getObject(.init(bucket: bucketSource.bucketName, key: key))
			.toCombine()
			.receive(on: DispatchQueue.main)
		
		func load() {
			self.cancellable = producer.sink { (completion) in
				print("COMPLETED", completion)
			} receiveValue: { (output) in
				self.getObjectOutput = output
			}
		}
	}
	
	func object(key: String) -> ObjectSource { .init(bucketSource: self, key: key) }
}

extension S3Source {
	func bucket(name: String) -> BucketSource { .init(bucketName: name, s3: producers.s3) }
}

extension StoresSource {
	func bucket(name: String) -> BucketSource { .init(bucketName: name, s3: s3) }
}

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
	
	@Published var getResult: Result<S3.GetObjectOutput, Error>?
	
	private lazy var getCancellable = producers.get()
		.catchAsResult()
		.sink { self.getResult = $0 }
	
	func load() {
		_ = getCancellable
	}
}

extension BucketSource {
	func useObject(key: String) -> S3ObjectSource { .init(bucketName: bucketName, objectKey: key, s3: producers.s3) }
}
