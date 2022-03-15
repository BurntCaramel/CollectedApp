//
//  FirstViewController.swift
//  Collected
//
//  Created by Patrick Smith on 8/9/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import UIKit
import UniformTypeIdentifiers
import MobileCoreServices
import SwiftUI
import Combine
import SotoS3
import NIO
import CryptoKit

class FirstViewController: UIViewController {
	override func viewDidLoad() {
		super.viewDidLoad()
	}
}

class FirstHostingController: UIHostingController<StoresView> {
	var settings = Settings.Source()
	var storesSource: StoresSource? {
		willSet {
			storesSource?.shutdown()
		}
		didSet {
			self.rootView = .init(storesSource: storesSource)
		}
	}
	
	var cancellables = Set<AnyCancellable>()
	
	required init?(coder decoder: NSCoder) {
		super.init(coder: decoder, rootView: StoresView(storesSource: storesSource))
	}
	
	override func viewDidAppear(_ animated: Bool) {
		settings.$awsCredentials.sink { [weak self] (awsCredentials) in
			self?.storesSource = StoresSource(awsCredentials: awsCredentials)
		}.store(in: &cancellables)
		
		settings.load()
		
		super.viewDidAppear(animated)
	}
	
	override func viewWillDisappear(_ animated: Bool) {
		cancellables.removeAll()
		self.storesSource = nil
		
		super.viewWillDisappear(animated)
	}
}

struct StoresView: View {
	var storesSource: StoresSource?
	
	var body: some View {
		VStack {
			if let storesSource = self.storesSource {
				ListStoresView(bucketsSource: storesSource.useBuckets())
			} else {
				Text("You must set up your AWS credentials first")
			}
		}
	}
}

struct ListStoresView: View {
	@ObservedObject var bucketsSource: S3Source
	
	var bucketNames: [String] {
		switch bucketsSource.bucketsResult {
		case .success(let buckets):
			return buckets.compactMap({ $0.name })
		default:
			return []
		}
	}
	
	var body: some View {
		NavigationView {
            switch bucketsSource.bucketsResult {
            case .none:
                Text("Loading…")
                    .navigationBarTitle("Buckets")
            case .some(.failure(let error)):
                Text("Error: \(error.localizedDescription)")
                    .navigationBarTitle("Buckets")
            case .some(.success(let buckets)):
                let bucketNames = buckets.compactMap({ $0.name })
                List {
                    ForEach(bucketNames, id: \.self) { bucketName in
                        NavigationLink(destination: BucketView(bucketSource: bucketsSource.bucket(name: bucketName))) {
                            Text(bucketName)
                        }
                    }
                }
                .navigationBarTitle("Buckets")
            }
		}
		.onAppear {
			self.bucketsSource.load()
		}
	}
}

struct BucketView: View {
	@ObservedObject var bucketSource: BucketSource
	
	enum Filter : String {
		case all
		case text
		case image
		case pdf
	}
	
	@State var filter: Filter = .image
	
	struct NewState {
		var mediaType = MediaType.text(.markdown)
		var stringContent = ""
		
		var content: ContentResource? {
            ContentResource(mediaType: mediaType, string: stringContent)
		}
	}
	@State var newState = NewState()
	@State var isDropActive = false
	
	private var bucketName: String { bucketSource.bucketName }
	
	struct Drop : DropDelegate {
		let bucketSource: BucketSource
		
		func performDrop(info: DropInfo) -> Bool {
			var count = 0
			
            for mediaType in [MediaType.text(.plain), .text(.markdown), .image(.png), .image(.gif), .image(.jpeg), .image(.tiff), .application(.pdf), .application(.json)] {
				let uti = mediaType.uti!
				let itemProviders = info.itemProviders(for: [uti])
				for item in itemProviders {
					_ = item.loadDataRepresentation(forTypeIdentifier: uti.identifier, completionHandler: { (data, error) in
						if let error = error {
							print("DROP ERROR", error, mediaType)
						}
						if let data = data {
							print("RECEIVED DATA", data)
							let content = ContentResource(data: data, mediaType: mediaType)
							bucketSource.createPublicReadable(content: content)
							count += 1
						}
					})
				}
			}
			
			return count > 0
		}
	}
	
	private var newFormView: some View {
		VStack {
            Group {
                Text("Drop file to upload").padding()
            }
            .foregroundColor(.white)
            .background(isDropActive ? Color.purple : Color.blue)
            .onDrop(of: [UTType.text, UTType.image, UTType.pdf], delegate: Drop(bucketSource: bucketSource))
            
            Form {
                TextEditor(text: $newState.stringContent)
                    .border(.gray, width: 1)
                
                Picker("Content Type", selection: $newState.mediaType) {
                    Text("Markdown").tag(MediaType.text(.markdown))
                    Text("Plain text").tag(MediaType.text(.plain))
                    Text("JSON").tag(MediaType.application(.json))
                    Text("JavaScript").tag(MediaType.application(.javascript))
                }.pickerStyle(.menu)
                
                if let content = newState.content {
                    Text(content.id.objectStorageKey)
                        .onTapGesture {
                            if let collectedPressURL = bucketSource.collectedPressRootURL?.appendingPathComponent(content.id.objectStorageKey) {
                                UIPasteboard.general.url = collectedPressURL
                            }
                        }
                    
                    Button("Create") {
                        bucketSource.createPublicReadable(content: content)
                    }
                }
            }
		}
	}
	
	var objects: [S3.Object] {
		switch filter {
		case .text:
			return bucketSource.textObjects ?? []
		case .image:
			return bucketSource.imageObjects ?? []
		case .pdf:
			return bucketSource.pdfObjects ?? []
		case .all:
			return bucketSource.objects ?? []
		}
	}
	
	struct DigestEmojidView: View {
		var digestHex: String
		
		let hexToEmoji: Dictionary<Character, String> = [
			"0": "⚡️", "1": "💩", "2": "💋", "3": "🦁", "4": "🐧", "5": "🦄", "6": "🐝", "7": "🐙", "8": "🌵", "9": "🍇", "a": "🍫", "b": "🎈", "c": "⛄", "d": "⛵️", "e": "🚲", "f": "👠"
		]
		
		var emojid: [String]? {
			let emojis = digestHex.prefix(7).compactMap{ hexToEmoji[$0] }
			guard emojis.count == 7 else { return nil }
			return emojis
		}
		
		var body: some View {
			if let emojid = emojid {
				HStack(alignment: /*@START_MENU_TOKEN@*/.center/*@END_MENU_TOKEN@*/, spacing: nil) {
					ForEach(emojid.indices) { index in
						Text(emojid[index]).font(index <= 3 ? .title2 : .body)
					}
				}
//				Text(emojid).font(.body).help(digestHex)
			} else {
				Text(digestHex).font(.caption)
			}
		}
	}
	
	struct DigestSymbolView: View {
		var digestHex: String
		
		let hexToSystemName: Dictionary<Character, String> = [
			"0": "suit.club.fill", "1": "suit.diamond.fill", "2": "heart.circle.fill", "3": "cursorarrow.rays", "4": "arrow.up.arrow.down.square.fill", "5": "bell.fill", "6": "eyebrow", "7": "flashlight.on.fill", "8": "line.3.crossed.swirl.circle", "9": "scissors", "a": "gyroscope", "b": "paintbrush.pointed.fill", "c": "key.fill", "d": "pin.circle.fill", "e": "bicycle", "f": "checkerboard.rectangle"
		]
		
		let hexToColor: Dictionary<Character, SwiftUI.Color> = [
			"0": Color.black, "1": .blue, "2": .orange, "3": .yellow, "4": .red, "5": .purple, "6": .pink, "7": .green, "8": .gray, "9": .red, "a": .blue, "b": .purple, "c": .orange, "d": .green, "e": .pink, "f": .black
		]
		
		let count = 5
		
		var symbols: [String]? {
			let symbols = digestHex.prefix(count).compactMap{ hexToSystemName[$0] }
			guard symbols.count == count else { return nil }
			return symbols
		}
		
		var colors: [Color]? {
			let colors = digestHex.dropFirst(count).prefix(count).compactMap{ hexToColor[$0] }
			guard colors.count == count else { return nil }
			return colors
		}
		
		var body: some View {
			if let symbols = symbols, let colors = colors {
				HStack(alignment: /*@START_MENU_TOKEN@*/.center/*@END_MENU_TOKEN@*/, spacing: nil) {
					ForEach(symbols.indices) { index in
						Image(systemName: symbols[index]).font(index % 2 == 0 ? .title : .body).foregroundColor(colors[index])
					}
				}
			} else {
				Text(digestHex).font(.caption)
			}
		}
	}
	
	struct ItemView: View {
		let key: String
        
        var contentIdentifier: ContentIdentifier? { .init(objectStorageKey: key) }
        
        var values: Optional<(imageName: String, text: String, contentIdentifier: ContentIdentifier)> {
            guard let contentIdentifier = contentIdentifier else { return nil }
            switch contentIdentifier.mediaType {
            case .text(let textType): return (imageName: "doc.plaintext", text: textType.rawValue, contentIdentifier: contentIdentifier)
            case .image(let imageType): return (imageName: "photo", text: imageType.rawValue, contentIdentifier: contentIdentifier)
            case .application(.pdf): return (imageName: "doc.richtext", text: "pdf", contentIdentifier: contentIdentifier)
            case .application(.javascript): return (imageName: "curlybraces.square", text: "javascript", contentIdentifier: contentIdentifier)
            case .application(.json): return (imageName: "curlybraces.square", text: "json", contentIdentifier: contentIdentifier)
            default: return nil
            }
        }
		
		var body: some View {
            if let values = self.values {
                HStack {
                    Image(systemName: values.imageName)
                    Text(values.text).textCase(.uppercase).font(.body)
                    DigestSymbolView(digestHex: values.contentIdentifier.sha256DigestHex)
                }
			} else {
				Text(key)
			}
		}
	}
	
	var body: some View {
		VStack {
			Text("Load #\(bucketSource.loadClock.counter)")
			
			switch filter {
			case .text:
				Text("").onAppear(perform: bucketSource.loadTexts)
			case .image:
				Text("").onAppear(perform: bucketSource.loadImages)
			case .pdf:
				Text("").onAppear(perform: bucketSource.loadPDFs)
			case .all:
				Text("").onAppear(perform: bucketSource.load)
			}
			
			Picker("Filter", selection: $filter) {
				Text("Images").tag(Filter.image)
				Text("Texts").tag(Filter.text)
				Text("PDFs").tag(Filter.pdf)
				Text("All").tag(Filter.all)
            }.pickerStyle(.segmented)
			List {
				ForEach(objects, id: \.key) { object in
					NavigationLink(destination: ObjectInfoView(object: object, objectSource: bucketSource.useObject(key: object.key ?? ""))) {
						HStack {
							ItemView(key: object.key ?? "")
								.contextMenu {
                                    Button("Make Public Readable") {
                                        if let key = object.key {
                                            bucketSource.makePublicReadable(key: key)
                                        }
                                    }
									Button("Delete") {
										if let key = object.key {
											print("DELETE!", key)
											bucketSource.delete(key: key)
										}
									}
								}
							Spacer()
							Text(ByteCountFormatter.string(fromByteCount: object.size ?? 0, countStyle: .file))
						}
					}
				}
				.onDelete { (indexSet) in
					guard let objects = bucketSource.objects else { return }
						
					for index in indexSet {
						let object = objects[index]
						if let key = object.key {
							print("DELETE!", key)
							bucketSource.delete(key: key)
						}
					}
				}
			}
			newFormView
		}
		.navigationBarTitle(bucketName)
		.onAppear(perform: bucketSource.load)
	}
}

struct ObjectInfoView: View {
	var object: S3.Object
	@ObservedObject var objectSource: S3ObjectSource
	
	var previewView: some View {
		if
			case let .success(output) = objectSource.getResult,
			let mediaType = output.contentType,
			let contentData = output.body?.asData()
		{
			return AnyView(
				VStack {
					ContentPreview.PreviewView(mediaType: MediaType(string: mediaType), contentData: contentData)
				}
			)
		}
		else {
			return AnyView(Text("HAS NO PREVIEW"))
		}
	}
	
	var body: some View {
		return VStack {
			Button(action: load) { Text("Load") }
            
            if let collectedPressURL = objectSource.collectedPressURL {
                Text(collectedPressURL.absoluteString)
                    .textSelection(.enabled)
                    .onTapGesture {
                        UIPasteboard.general.url = collectedPressURL
                    }
            }
			
			VStack {
				self.previewView
			}
		}
		.navigationBarTitle("\(objectSource.objectKey)", displayMode: .inline)
		.onAppear(perform: load)
	}
	
	private func load() {
		objectSource.load()
	}
}
