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
	private let s3Global: S3
	
	init(awsCredentials: Settings.AWSCredentials) {
		awsClient = AWSClient(credentialProvider: .static(accessKeyId: awsCredentials.accessKeyID, secretAccessKey: awsCredentials.secretAccessKey), httpClientProvider: .createNew)
		s3Global = S3(client: awsClient)
	}
	
	private func s3InCorrectRegion(bucketName: String) async throws -> S3 {
		let s3Global = S3(client: awsClient)
		let location = try await s3Global.getBucketLocation(.init(bucket: bucketName, expectedBucketOwner: nil))
		let locationConstraint = location.locationConstraint!
		let region = Region(awsRegionName: locationConstraint.rawValue)
		return S3(client: awsClient, region: region)
	}
	
	func bucketInCorrectedRegion(name: String) async throws -> BucketSource {
		let s3 = try await s3InCorrectRegion(bucketName: name)
		return BucketSource(bucketName: name, s3: s3)
	}
	
	func listS3Buckets() async throws -> [S3.Bucket] {
		print("listS3Buckets")
		return try await s3Global.listBuckets().buckets ?? []
	}
	
	func shutdown() {
		try? awsClient.syncShutdown()
	}
}

class BucketSource {
	let bucketName: String
	let s3: S3
	
	struct ListFilter {
		enum ContentType {
			case all
			case texts
			case images
			case pdfs
			case sqlite
			
			var prefix: String? {
				switch self {
				case .all:
					return nil
				case .texts:
					return "sha256/text/"
				case .images:
					return "sha256/image/"
				case .pdfs:
					return "sha256/\(MediaType.application(.pdf))/"
				case .sqlite:
					return "sha256/\(MediaType.application(.sqlite3))/"
				}
			}
		}
		var contentType: ContentType
	}
	
	fileprivate init(bucketName: String, s3: S3) {
		self.bucketName = bucketName
		self.s3 = s3
	}
	
	static func local() -> BucketSource {
		let awsClient = AWSClient(credentialProvider: .configFile(), httpClientProvider: .createNew)
		return BucketSource(bucketName: "", s3: SotoS3.S3(client: awsClient))
	}
	
	func shutdown() {
		try? s3.client.syncShutdown()
	}
	
	var region: Region {
		s3.region
	}
	
	func list(filter: ListFilter) async throws -> [S3.Object] {
		print("PREFIX \(filter.contentType.prefix)")
		let objects = try await s3.listObjectsV2(.init(bucket: bucketName, prefix: filter.contentType.prefix))
		return objects.contents ?? []
	}
	
	func listAll() async throws -> [S3.Object] {
		try await list(filter: .init(contentType: .all))
	}
	
	func listTexts() async throws -> [S3.Object] {
		try await list(filter: .init(contentType: .texts))
	}
	
	func listImages() async throws -> [S3.Object] {
		try await list(filter: .init(contentType: .images))
	}
	
	func listPDFs() async throws -> [S3.Object] {
		try await list(filter: .init(contentType: .pdfs))
	}
	
	func listSQLiteDatabases() async throws -> [S3.Object] {
		try await list(filter: .init(contentType: .sqlite))
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
	
	func createPublicReadableRedirect(key: String, redirectLocation: String) async throws -> S3.PutObjectOutput {
		let request = S3.PutObjectRequest(acl: .publicRead, bucket: bucketName, key: key, metadata: ["x-amz-website-redirect-location": redirectLocation])
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
	
	func url(key: String) -> URL {
		return URL(string: "https://\(bucketName).s3.\(region).amazonaws.com/\(key)")!
	}
	
	func signedURL(key: String) async throws -> URL {
		return try await s3.signURL(url: url(key: key), httpMethod: .GET, expires: .hours(24))
	}
	
	var collectedPressRootURL: URL? {
		URL(string: "https://collected.press/1/s3/object/\(region.rawValue)/\(bucketName)/")
	}
}
