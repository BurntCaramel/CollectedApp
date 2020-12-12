//
//  ContentPreview.swift
//  Collected
//
//  Created by Patrick Smith on 11/9/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import Foundation
import SwiftUI

enum ContentPreview {
	struct PreviewView: View {
		var mediaType: MediaType
		var contentData: Data
		
		var body: some View {
			VStack {
				switch mediaType {
				case .text:
					TextPreview(contentData: contentData)
				case .image:
					ImagePreview(contentData: contentData)
				default:
					Text("Can’t preview \(mediaType.string)")
				}
			}
		}
	}
	
	private struct TextPreview: View {
		var contentData: Data
		
		var contentString: String? {
			String(data: contentData, encoding: .utf8)
		}
		
		var body: some View {
			Text(contentString ?? "")
				.frame(maxWidth: .infinity)
				.border(Color.gray)
		}
	}
	
	private struct ImagePreview: View {
		var contentData: Data
		
		struct DecodedImage {
			var uiImage: UIImage
			private var propertiesRaw: CFDictionary?
			private var properties: NSDictionary? { propertiesRaw }
			
			var pixelWidth: CGFloat? {
				properties?.value(forKey: kCGImagePropertyPixelWidth as String) as? CGFloat
			}
			var pixelHeight: CGFloat? {
				properties?.value(forKey: kCGImagePropertyPixelHeight as String) as? CGFloat
			}
			
			init?(data: Data) {
				guard let imageSource = CGImageSourceCreateWithData(data as NSData, nil) else { return nil }
				let index = CGImageSourceGetPrimaryImageIndex(imageSource)
				self.propertiesRaw = CGImageSourceCopyPropertiesAtIndex(imageSource, index, nil)
				guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else { return nil }
				self.uiImage = UIImage(cgImage: cgImage)
			}
		}
		
		var decodedImage: DecodedImage? {
			return DecodedImage(data: contentData)
		}
		
		var body: some View {
			if let decodedImage = decodedImage {
				VStack {
					HStack {
						if let pixelWidth = decodedImage.pixelWidth {
							Text("Width: \(pixelWidth, specifier: "%.0f")")
						}
						if let pixelHeight = decodedImage.pixelHeight {
							Text("Height: \(pixelHeight, specifier: "%.0f")")
						}
					}
					Image(uiImage: decodedImage.uiImage)
						.resizable()
						.aspectRatio(contentMode: .fit)
				}
			} else {
				Text("Can’t preview image")
			}
		}
	}
}
