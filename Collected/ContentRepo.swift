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
	
	func createObject(bucketName: String, content: ContentResource) -> AnyPublisher<S3.PutObjectOutput, Error> {
		let contentType = content.id.mediaType.string
		let digest = content.id.sha256Digest
		let digestHex = digest.map { String(format: "%02x", $0) }.joined()
		let key = "sha256/\(contentType)/\(digestHex)"
		print("PUT OBJECT: KEY", key)
		let request = S3.PutObjectRequest(body: content.data, bucket: bucketName, contentType: contentType, key: key)
		return s3.putObject(request)
			.toCombine()
			.print()
			.receive(on: DispatchQueue.main)
			//            .replaceError(with: nil)
			.eraseToAnyPublisher()
	}
}

class BucketSource : ObservableObject {
	let bucketName: String
	
	private let s3: S3
	
	fileprivate init(bucketName: String, s3: S3) {
		self.bucketName = bucketName
		self.s3 = s3
	}
	
	@Published var objects: [S3.Object]?
	
	var listCancellables = Set<AnyCancellable>()
	var createCancellables = Set<AnyCancellable>()
	var deleteCancellables = Set<AnyCancellable>()
	
	private lazy var listProducer = Deferred { [s3, bucketName] in s3.listObjectsV2(.init(bucket: bucketName)) }
		.map({ $0.contents?.compactMap({ $0 }) ?? [] })
		.replaceError(with: [])
		.receive(on: DispatchQueue.main)
		.eraseToAnyPublisher()
	
	func load() {
		print("RELOADING list bucket")
		listCancellables.removeAll()
		
		listProducer
			.sink { self.objects = $0 }
			.store(in: &listCancellables)
	}
	
	func create(content: ContentResource) {
		let contentID = content.id
		let key = contentID.objectStorageKey
		print("PUT OBJECT: KEY", key)
		
		let request = S3.PutObjectRequest(body: content.data, bucket: bucketName, contentType: contentID.mediaType.string, key: key)
		s3.putObject(request)
			.toCombine()
			.print()
			.receive(on: DispatchQueue.main)
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
		let request = S3.DeleteObjectRequest(bucket: bucketName, key: key)
		s3.deleteObject(request)
			.toCombine()
			.print()
			.receive(on: DispatchQueue.main)
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

extension StoresSource {
	func bucket(name: String) -> BucketSource { .init(bucketName: name, s3: s3) }
}
