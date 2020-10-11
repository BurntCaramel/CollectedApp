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
        var mediaType: String
        var contentData: Data
        
        var body: some View {
            VStack {
                if (mediaType.starts(with: "text/")) {
                    TextPreviewView(mediaType: mediaType, contentData: contentData)
                } else {
                    Text("Can’t preview")
                }
            }
        }
    }
    
    struct TextPreviewView: View {
        var mediaType: String
        var contentData: Data
        
        var contentString: String? {
            String(data: contentData, encoding: .utf8)
        }
        
        var body: some View {
            Text(contentString ?? "")
                .border(Color.gray)
        }
    }
}
