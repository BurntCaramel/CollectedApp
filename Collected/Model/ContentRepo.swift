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
//	private let s3: S3
	
	init(awsCredentials: Settings.AWSCredentials) {
		awsClient = AWSClient(credentialProvider: .static(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey), httpClientProvider: .createNew)
//		s3 = S3(client: awsClient)
	}
	
	func bucketInCorrectedRegion(name: String) async throws -> BucketSource {
		return try await BucketSource(bucketName: name, awsClient: awsClient)
	}
	
	func listS3Buckets() async throws -> [S3.Bucket] {
		let s3 = S3(client: awsClient)
		return try await s3.listBuckets().buckets ?? []
	}
	
	func shutdown() {
		try? awsClient.syncShutdown()
	}
}

class BucketSource : ObservableObject {
	let bucketName: String
	let s3: S3
	
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
	
	fileprivate struct Producers {
		let bucketName: String
		let s3: S3
		
		fileprivate init(bucketName: String, awsClient: AWSClient) async throws {
			let s3Global = S3(client: awsClient)
			let location = try await s3Global.getBucketLocation(.init(bucket: bucketName, expectedBucketOwner: nil))
			let locationConstraint = location.locationConstraint!
			let region = Region(awsRegionName: locationConstraint.rawValue)
			let s3 = S3(client: awsClient, region: region)
			
			self.bucketName = bucketName
			self.s3 = s3
		}
		
		func list(filter: ListFilter) async throws -> [S3.Object] {
			let objects = try await s3.listObjectsV2(.init(bucket: bucketName, prefix: filter.contentType.prefix))
			return objects.contents ?? []
		}
		
		func list(region: Region, filter: ListFilter) async throws -> [S3.Object] {
			let s3 = S3(client: self.s3.client, region: region)
			let objects = try await s3.listObjectsV2(.init(bucket: bucketName, prefix: filter.contentType.prefix))
			return objects.contents ?? []
		}
		
		func getObject(key: String) async throws -> S3.GetObjectOutput {
			return try await s3.getObject(.init(bucket: bucketName, key: key))
		}
		
		func delete(key: String) async throws -> S3.DeleteObjectOutput {
			return try await s3.deleteObject(.init(bucket: bucketName, key: key))
		}
		
		func createPublicReadable(content: ContentResource) async throws -> S3.PutObjectOutput {
			let contentID = content.id
			let key = contentID.objectStorageKey
			let request = S3.PutObjectRequest(acl: .publicRead, body: AWSPayload.data(content.data), bucket: bucketName, contentType: contentID.mediaType.string, key: key)
			return try await s3.putObject(request)
		}
		
		func makePublicReadable(contentID: ContentIdentifier) async throws -> S3.PutObjectAclOutput {
			let key = contentID.objectStorageKey
			return try await makePublicReadable(key: key)
		}
		
		func makePublicReadable(key: String) async throws -> S3.PutObjectAclOutput {
			let request = S3.PutObjectAclRequest(acl: .publicRead, bucket: bucketName, key: key)
			return try await s3.putObjectAcl(request)
		}
	}
	fileprivate let producers: Producers
	
	fileprivate init(bucketName: String, awsClient: AWSClient) async throws {
		self.bucketName = bucketName
		self.producers = try await .init(bucketName: bucketName, awsClient: awsClient)
		self.s3 = self.producers.s3
	}
	
	var region: Region {
		producers.s3.region
	}
	
	var collectedPressRootURL: URL? {
		URL(string: "https://collected.press/1/s3/object/\(region.rawValue)/\(bucketName)/")
	}
	
	func listAll(region: Region) async throws -> [S3.Object] {
		try await producers.list(region: region, filter: .init(contentType: .all))
	}
	
	func listAll() async throws -> [S3.Object] {
		try await producers.list(filter: .init(contentType: .all))
	}
	
	func listTexts() async throws -> [S3.Object] {
		try await producers.list(filter: .init(contentType: .texts))
	}
	
	func listImages() async throws -> [S3.Object] {
		try await producers.list(filter: .init(contentType: .images))
	}
	
	func listPDFs() async throws -> [S3.Object] {
		try await producers.list(filter: .init(contentType: .pdfs))
	}
	
	func getObject(key: String) async throws -> S3.GetObjectOutput {
		try await producers.getObject(key: key)
	}
	
	func delete(key: String) async throws -> S3.DeleteObjectOutput {
		try await producers.delete(key: key)
	}
	
	func createPublicReadable(content: ContentResource) async throws {
		let _ = try await producers.createPublicReadable(content: content)
	}
	
	func makePublicReadable(key: String) async throws {
		let _ = try await producers.makePublicReadable(key: key)
	}
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
