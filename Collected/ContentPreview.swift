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
		
		var uiImage: UIImage? {
			UIImage(data: contentData)
		}
		
		var body: some View {
			if let uiImage = uiImage {
				Image(uiImage: uiImage)
			} else {
				Text("Can’t preview image")
			}
		}
	}
}
