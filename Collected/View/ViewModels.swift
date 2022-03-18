//
//  ViewModels.swift
//  Collected
//
//  Created by Patrick Smith on 18/3/2022.
//  Copyright © 2022 Patrick Smith. All rights reserved.
//

import Foundation
import SotoS3
import UIKit


@MainActor
class BucketViewModel: ObservableObject {
	private var bucket: BucketSource
	
	struct Object {
		let key: String
		let size: Int64
		
		init?(object: S3.Object) {
			guard let key = object.key, let size = object.size else { return nil }
			self.key = key
			self.size = size
		}
	}
	
	@Published var loadCount = 0
	@Published var objects: [Object]?
	@Published var imageObjects: [Object]?
	@Published var textObjects: [Object]?
	@Published var pdfObjects: [Object]?
	@Published var error: Error?
	
	/*struct Model {
		let locationConstraint: S3.BucketLocationConstraint
		var objects: [S3.Object]
	}*/
	
	init(bucketSource: BucketSource) {
		self.bucket = bucketSource
	}
	
	var bucketName: String { bucket.bucketName }
	var region: Region { bucket.region }
	var collectedPressRootURL: URL {
		URL(string: "https://collected.press/1/s3/object/\(region.rawValue)/\(bucketName)/")!
	}
	var collectedPressRootHighlightURL: URL {
		URL(string: "https://collected.press/1/s3/highlight/\(region.rawValue)/\(bucketName)/")!
	}
	var collectedPressRootHighlightURLComponents: URLComponents {
		URLComponents(string: "https://collected.press/1/s3/highlight/\(region.rawValue)/\(bucketName)/")!
	}
	
	func collectedPressURL(contentID: ContentIdentifier) -> URL {
		collectedPressRootURL.appendingPathComponent(contentID.objectStorageKey)
	}
	func collectedPressHighlightURL(contentID: ContentIdentifier) -> URL {
		var urlComponents = collectedPressRootHighlightURLComponents
		urlComponents.path += contentID.objectStorageKey
		urlComponents.queryItems = [URLQueryItem(name: "theme", value: "1")]
		return urlComponents.url!
	}
	
	func downloadObject(key: String) async throws -> (mediaType: MediaType, contentData: Data)? {
		do {
			let output = try await bucket.getObject(key: key)
			guard let mediaType = output.contentType, let contentData = output.body?.asData() else { return nil }
			return (mediaType: MediaType(string: mediaType), contentData: contentData)
		}
		catch (let error) {
			self.error = error
			return nil
		}
	}
	
	func delete(key: String) async {
		do {
			let _ = try await bucket.delete(key: key)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func load() async {
		do {
			print("will reload list")
			objects = try await bucket.listAll().compactMap(Object.init)
			print("did reload list")
			loadCount += 1
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func loadImages() async {
		do {
			imageObjects = try await bucket.listImages().compactMap(Object.init)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func loadTexts() async {
		do {
			textObjects = try await bucket.listTexts().compactMap(Object.init)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func loadPDFs() async {
		do {
			pdfObjects = try await bucket.listPDFs().compactMap(Object.init)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func createPublicReadable(content: ContentResource) async {
		do {
			let _ = try await bucket.createPublicReadable(content: content)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func makePublicReadable(key: String) async {
		do {
			let _ = try await bucket.makePublicReadable(key: key)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func url(key: String) -> URL {
		bucket.url(key: key)
	}
	
	func copyURL(key: String) {
		let url = bucket.url(key: key)
		UIPasteboard.general.string = url.absoluteString
//			UIPasteboard.general.url = url
	}
}
