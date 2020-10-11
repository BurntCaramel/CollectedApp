//
//  Content.swift
//  Collected
//
//  Created by Patrick Smith on 11/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import Foundation

// See: https://github.com/onevcat/MimeType/blob/master/Sources/MimeType.swift

enum MediaType {
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
	case text(unknown: String)
	case image(Image)
	case image(unknown: String)
	case other(raw: String)
	
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
					self = .text(unknown: subtypeRaw)
				}
			case .image:
				if let imageType = Image(rawValue: subtypeRaw) {
					self = .image(imageType)
				} else {
					self = .image(unknown: subtypeRaw)
				}
			default:
				// TODO: Other cases
				self = .other(raw: string)
			}
		} else {
			self = .other(raw: string)
		}
		
		return nil
	}
}
