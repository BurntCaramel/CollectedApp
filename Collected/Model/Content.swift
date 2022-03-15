//
//  Content.swift
//  Collected
//
//  Created by Patrick Smith on 11/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import Foundation
import CryptoKit
import UniformTypeIdentifiers

// See: https://github.com/onevcat/MimeType/blob/master/Sources/MimeType.swift

enum MediaType : Hashable {
	enum Base : String {
		case text
		case image
		case audio
		case video
		case application
	}
	
	enum Text : String {
		case plain
		case json
		case markdown
		case html
		case css
		case xml
	}
	
	enum Image : String {
		case png
		case jpeg
		case gif
		case tiff
		case svg = "svg+xml"
		case webp
	}
	
	enum Application : String {
		case json
		case rss = "rss+xml"
		case atom = "atom+xml"
		case wasm
		case javascript
		case pdf
		case zip
		case fontWoff = "font-woff"
		case octetStream = "octet-stream"
	}
	
	case text(Text)
	//	case text(unknown: String)
	case image(Image)
	//	case image(unknown: String)
	case application(Application)
	case other(baseType: Base, subType: String)
	case unknown(raw: String)
	
	init<S>(string: S) where S: StringProtocol {
		let components = string.split(separator: "/", maxSplits: 1)
		let baseRaw = String(components[0])
		let subtypeRaw = String(components[1])
		if let base = Base(rawValue: baseRaw) {
			switch base {
			case .text:
				if let textType = Text(rawValue: subtypeRaw) {
					self = .text(textType)
				} else {
					self = .other(baseType: .text, subType: subtypeRaw)
				}
			case .image:
				if let imageType = Image(rawValue: subtypeRaw) {
					self = .image(imageType)
				} else {
					self = .other(baseType: .image, subType: subtypeRaw)
				}
			case .application:
				if let applicationType = Application(rawValue: subtypeRaw) {
					self = .application(applicationType)
				} else {
					self = .other(baseType: .application, subType: subtypeRaw)
				}
			default:
				// TODO: Other cases
				self = .unknown(raw: String(string))
			}
		} else {
			self = .unknown(raw: String(string))
		}
	}
	
	var string: String {
		switch self {
		case let .text(textType):
			return "text/\(textType.rawValue)"
		case let .image(imageType):
			return "image/\(imageType.rawValue)"
		case let .application(applicationType):
			return "application/\(applicationType.rawValue)"
		default:
			return ""
		}
	}
	
	var uti: UTType? {
		switch self {
		case let .text(textType):
			switch textType {
			case .plain: return .plainText
			case .markdown: return UTType(exportedAs: "net.daringfireball.markdown", conformingTo: .plainText)
			case .html: return .html
			case .json: return .json
			case .css: return .plainText
			case .xml: return .xml
			}
		case let .image(imageType):
			switch imageType {
			case .png: return .png
			case .gif: return .gif
			case .jpeg: return .jpeg
			case .tiff: return .tiff
			case .svg: return .svg
			case .webp: return .webP
			}
		case let .application(applicationType):
			switch applicationType {
			case .pdf: return .pdf
			case .javascript: return .javaScript
			case .octetStream: return .data
			case .json: return .json
			case .rss: return .xml
			case .zip: return .zip
			case .fontWoff: return .data
			case .wasm: return .data
			case .atom: return .xml
			}
		default:
			return nil
		}
	}
}

struct ContentIdentifier: Hashable {
	var mediaType: MediaType
	var sha256DigestHex: String
	var objectStorageKey: String { "sha256/\(mediaType.string)/\(sha256DigestHex)" }
}

extension ContentIdentifier {
	init(mediaType: MediaType, sha256Digest: SHA256Digest) {
		self.init(mediaType: mediaType, sha256DigestHex: sha256Digest.map { String(format: "%02x", $0) }.joined())
	}
	
	init?(objectStorageKey: String) {
		let components = objectStorageKey.split(separator: "/")
		guard components.count == 4 else { return nil }
		guard components[0] == "sha256" else { return nil }
		
		let rawMediaType = objectStorageKey[components[1].startIndex ..< components[2].endIndex]
		self.mediaType = MediaType(string: rawMediaType)
		
		let hexEncoded = components[3]
		self.sha256DigestHex = String(hexEncoded)
//		let bytes = stride(from: 0, to: hexEncoded.count, by: 2)
//			.compactMap { offset in
//				let index = hexEncoded.index(hexEncoded.startIndex, offsetBy: offset)
//				let nextIndex = hexEncoded.index(after: index)
//				UInt8(hexEncoded[index ..< nextIndex])
//				//hexEncoded[hexEncoded.$0]
//			}
	}
}

struct ContentResource : Identifiable {
	let data: Data
	let id: ContentIdentifier
	
	init(data: Data, mediaType: MediaType) {
		self.data = data
		let mediaType = mediaType
		let sha256Digest = SHA256.hash(data: data)
		self.id = .init(mediaType: mediaType, sha256Digest: sha256Digest)
	}
}

extension ContentResource {
	init?(textType: MediaType.Text, string: String) {
        self.init(mediaType: .text(textType), string: string)
	}
    
    init?(mediaType: MediaType, string: String) {
        guard let data = string.data(using: .utf8) else { return nil }
        self.init(data: data, mediaType: mediaType)
    }
}
