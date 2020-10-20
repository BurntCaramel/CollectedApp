//
//  FirstViewController.swift
//  Collected
//
//  Created by Patrick Smith on 8/9/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import UIKit
import SwiftUI
import Combine
import S3
import NIO
import CryptoKit

class FirstViewController: UIViewController {
	override func viewDidLoad() {
		super.viewDidLoad()
	}
}

class FirstHostingController: UIHostingController<StoresView> {
	var settings = Settings.Source()
	
	required init?(coder decoder: NSCoder) {
		super.init(coder: decoder, rootView: StoresView(settings: settings))
	}
}

struct StoresView: View {
	@ObservedObject var settings: Settings.Source
	//@ObservedObject var storesSource: StoresSource
	@State var storesSource: StoresSource?
	
	@ViewBuilder
	private var inner: some View {
		if let storesSource = self.storesSource {
			ListStoresView()
				.environmentObject(storesSource)
		} else {
			Text("Set ")
		}
	}
	
	var body: some View {
		VStack {
			if let storesSource = self.storesSource {
				//				let storesSource = self.storesSource!
				ListStoresView()
					.environmentObject(storesSource)
			} else {
				Text("Set ")
			}
		}
		.onAppear { settings.load() }
		.onReceive(settings.$awsCredentials) { (awsCredentials) in
			storesSource = .init(awsCredentials: awsCredentials)
		}
	}
}

struct ListStoresView: View {
	@EnvironmentObject var storesSource: StoresSource
	
	var bucketNames: [String] {
		switch storesSource.buckets {
		case .some(let buckets):
			return buckets.compactMap({ $0.name })
		default:
			return []
		}
	}
	
	var body: some View {
		NavigationView {
			List {
				ForEach(bucketNames, id: \.self) { bucketName in
					NavigationLink(destination: BucketView(bucketSource: storesSource.bucket(name: bucketName))) {
						Text(bucketName)
					}
				}
			}
			.navigationBarTitle("Buckets")
		}
		.onAppear {
			self.storesSource.load()
		}
	}
}

struct BucketView: View {
	@ObservedObject var bucketSource: BucketSource
	
	enum Filter : String {
		case all
		case text
		case image
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
	
	private var newFormView: some View {
		HStack {
			Form {
				TextField("Key", text: $newState.key)
				Picker("Media Type", selection: $newState.mediaType) {
					Text("Plain text").tag(MediaType.text(.plain))
					Text("Markdown").tag(MediaType.text(.markdown))
					Text("JSON").tag(MediaType.text(.json))
				}
				TextField("Content", text: $newState.stringContent)
				Button("Create") {
					if let content = newState.content {
						bucketSource.create(content: content)
					}
				}
			}
			
			Spacer()
			
			Text("Drag and drop")
		}
		.background(isDropActive ? Color.red : Color.blue)
		.onDrop(of: [kUTTypeText as String], isTargeted: $isDropActive) { (items) -> Bool in
			print(kUTTypeText, kUTTypePlainText)
			print("DROP", items)
			for item in items {
				item.loadDataRepresentation(forTypeIdentifier: kUTTypeText as String) { (data, error) in
					if let error = error {
						print("DROP ERROR", error)
					}
					if let data = data {
						print("RECEIVED DATA", data)
						let content = ContentResource(data: data, mediaType: .text(.plain))
						bucketSource.create(content: content)
					}
				}
			}
			return true
		}
	}
	
	var body: some View {
		VStack {
			Picker("Filter", selection: $filter) {
				Text("All").tag(Filter.all)
				Text("Texts").tag(Filter.text)
				Text("Images").tag(Filter.image)
			}.pickerStyle(SegmentedPickerStyle())
			List {
				ForEach(bucketSource.objects ?? [], id: \.key) { object in
					NavigationLink(destination: ObjectInfoView(bucketName: self.bucketName, objectKey: object.key ?? "", object: object)) {
						Text(object.key ?? "")
					}
					.contextMenu {
						Button("Delete") {
							if let key = object.key {
								print("DELETE!", key)
								bucketSource.delete(key: key)
							}
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
	var bucketName: String
	var objectKey: String
	var object: S3.Object
	
	@EnvironmentObject var storesSource: StoresSource
	@State var output: S3.GetObjectOutput?
	@State var cancellables = Set<AnyCancellable>()
	
	var objectPublisher: Publishers.MakeConnectable<AnyPublisher<S3.GetObjectOutput, Never>> {
		storesSource.loadObject(bucketName: bucketName, objectKey: objectKey)
	}
	
	var previewView: some View {
		if let output = self.output, let mediaType = output.contentType, let contentData = output.body {
			return AnyView(
				VStack {
					ContentPreview.PreviewView(mediaType: mediaType, contentData: contentData)
				}
			)
		} else {
			return AnyView(Text("HAS NO PREVIEW"))
		}
	}
	
	var body: some View {
		return VStack {
			Text(objectKey)
			Text("Size: \(object.size ?? 0)")
			Text("Content type: \(output?.contentType ?? "")")
			Text("Content bytes: \(output?.body?.count ?? 0)")
			Button(action: load) { Text("Load") }
			
			VStack {
				Text("preview!")
				self.previewView
			}
		}
		.navigationBarTitle("\(objectKey)", displayMode: .inline)
		.onAppear(perform: load)
		.onReceive(objectPublisher) { (output) in
			if output.eTag != self.output?.eTag {
				self.output = output
			}
		}
	}
	
	func load() {
		objectPublisher.connect().store(in: &cancellables)
	}
}
