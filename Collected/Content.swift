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
	
	init(string: String) {
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
			default:
				// TODO: Other cases
				self = .unknown(raw: string)
			}
		} else {
			self = .unknown(raw: string)
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
	var sha256Digest: SHA256Digest
	
	var digestHex: String { sha256Digest.map { String(format: "%02x", $0) }.joined() }
	var objectStorageKey: String { "sha256/\(mediaType.string)/\(digestHex)" }
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
		guard let data = string.data(using: .utf8) else { return nil }
		self.init(data: data, mediaType: .text(textType))
	}
}
