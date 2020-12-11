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
			List {
				ForEach(bucketNames, id: \.self) { bucketName in
					NavigationLink(destination: BucketView(bucketSource: bucketsSource.bucket(name: bucketName))) {
						Text(bucketName)
					}
				}
			}
			.navigationBarTitle("Buckets")
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
	
	@State var filter: Filter = .all
	
	struct NewState {
		var key = ""
		var mediaType = MediaType.text(.markdown)
		var stringContent = ""
		
		var content: ContentResource? {
			ContentResource(textType: .plain, string: stringContent)
		}
	}
	@State var newState = NewState()
	@State var isDropActive = false
	
	private var bucketName: String { bucketSource.bucketName }
	
	struct Drop : DropDelegate {
		let bucketSource: BucketSource
		
		func performDrop(info: DropInfo) -> Bool {
			var count = 0
			
			for mediaType in [MediaType.text(.plain), .image(.png), .application(.pdf)] {
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
							bucketSource.create(content: content)
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
			Form {
				TextField("Key", text: $newState.key)
				Picker("Media Type", selection: $newState.mediaType) {
					Text("Plain text").tag(MediaType.text(.plain))
					Text("Markdown").tag(MediaType.text(.markdown))
					Text("JSON").tag(MediaType.text(.json))
				}
				TextField("Content", text: $newState.stringContent)
					.lineLimit(6)
				Button("Create") {
					if let content = newState.content {
						bucketSource.create(content: content)
					}
				}
			}
			
			Text("Drop to upload")
		}
		.background(isDropActive ? Color.red : Color.blue)
		.onDrop(of: [UTType.text, UTType.pdf], delegate: Drop(bucketSource: bucketSource))
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
				Text("All").tag(Filter.all)
				Text("Texts").tag(Filter.text)
				Text("Images").tag(Filter.image)
				Text("PDFs").tag(Filter.pdf)
			}.pickerStyle(SegmentedPickerStyle())
			List {
				ForEach(objects, id: \.key) { object in
					NavigationLink(destination: ObjectInfoView(object: object, objectSource: bucketSource.useObject(key: object.key ?? ""))) {
						HStack {
							Text(object.key ?? "")
								.contextMenu {
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
			Text(objectSource.objectKey)
			Button(action: load) { Text("Load") }
			
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
