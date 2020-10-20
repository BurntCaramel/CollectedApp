//
//  Content.swift
//  Collected
//
//  Created by Patrick Smith on 11/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import Foundation
import CryptoKit

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
	case other(baseType: Base, subType: String)
	case unknown(raw: String)
	
	init?(string: String) {
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
		
		return nil
	}
	
	var string: String {
		switch self {
		case let .text(textType):
			return "text/\(textType.rawValue)"
		default:
			return ""
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
