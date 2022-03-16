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
//			self?.rootView = StoresView(storesSource: self!.storesSource)
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
				ListBucketsView(storesSource: storesSource)
			} else {
				Text("You must set up your AWS credentials first")
			}
		}
	}
}

@MainActor
class BucketViewModel: ObservableObject {
	var bucketSource: BucketSource
	
	struct Object {
		let key: String
		let size: Int64
		
		init?(object: S3.Object) {
			guard let key = object.key, let size = object.size else { return nil }
			self.key = key
			self.size = size
		}
	}
	
	@Published var loadCount = 0
	@Published var objects: [Object]?
	@Published var imageObjects: [Object]?
	@Published var textObjects: [Object]?
	@Published var pdfObjects: [Object]?
	@Published var error: Error?
	
	/*struct Model {
		let locationConstraint: S3.BucketLocationConstraint
		var objects: [S3.Object]
	}*/
	
	init(bucketSource: BucketSource) {
		self.bucketSource = bucketSource
		
//		Task {
//			await load()
//		}
	}
	
	var bucketName: String { bucketSource.bucketName }
	var region: Region { bucketSource.region }
	var collectedPressRootURL: URL {
		URL(string: "https://collected.press/1/s3/object/\(region.rawValue)/\(bucketName)/")!
	}
	
	func collectedPressURL(contentID: ContentIdentifier) -> URL {
		collectedPressRootURL.appendingPathComponent(contentID.objectStorageKey)
	}
	
	func downloadObject(key: String) async throws -> (mediaType: MediaType, contentData: Data)? {
		do {
			let output = try await bucketSource.getObject(key: key)
			guard let mediaType = output.contentType, let contentData = output.body?.asData() else { return nil }
			return (mediaType: MediaType(string: mediaType), contentData: contentData)
		}
		catch (let error) {
			self.error = error
			return nil
		}
	}
	
	func delete(key: String) async {
		do {
			let _ = try await bucketSource.delete(key: key)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func load() async {
		do {
			print("will reload list")
			objects = try await bucketSource.listAll().compactMap(Object.init)
			print("did reload list")
			loadCount += 1
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func loadImages() async {
		do {
			imageObjects = try await bucketSource.listImages().compactMap(Object.init)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func loadTexts() async {
		do {
			textObjects = try await bucketSource.listTexts().compactMap(Object.init)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func loadPDFs() async {
		do {
			pdfObjects = try await bucketSource.listPDFs().compactMap(Object.init)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func createPublicReadable(content: ContentResource) async {
		do {
			try await bucketSource.createPublicReadable(content: content)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func makePublicReadable(key: String) async {
		do {
			try await bucketSource.makePublicReadable(key: key)
		}
		catch (let error) {
			self.error = error
		}
	}
}

struct BucketInfoView: View {
	@ObservedObject var bucketViewModel: BucketViewModel
	
	var body: some View {
		Text("Region: \(bucketViewModel.region.rawValue)")
	}
}

struct ListBucketsView: View {
	@ObservedObject var storesSource: StoresSource
	
	var body: some View {
		NavigationView {
			AsyncView(loader: { try await storesSource.listS3Buckets() }) { result in
				switch result {
				case .none:
					Text("Loading…")
				case .some(.failure(let error)):
					Text("Error: \(error.localizedDescription)")
				case .some(.success(let buckets)):
					let bucketNames = buckets.compactMap({ $0.name })
					List {
						ForEach(bucketNames, id: \.self) { bucketName in
							NavigationLink(destination: BucketView.Loader(storesSource: storesSource, bucketName: bucketName)) {
								Text(bucketName)
							}
						}
					}
				}
			}
			.navigationBarTitle("Buckets")
		}
	}
}

struct NewBucketObjectFormView: View {
	@ObservedObject var vm: BucketViewModel
	
	struct NewState {
		var mediaType = MediaType.text(.markdown)
		var stringContent = ""
		
		var content: ContentResource? {
			ContentResource(mediaType: mediaType, string: stringContent)
		}
	}
	@State var newState = NewState()
	@State var isDropActive = false
	
	@Environment(\.presentationMode) var presentationMode
	
	var body: some View {
		VStack {
			Group {
				Text("Drop file to upload").padding()
			}
			.foregroundColor(.white)
			.background(isDropActive ? Color.purple : Color.blue)
			.onDrop(of: [UTType.text, UTType.image, UTType.pdf], delegate: Drop(vm: vm))
			
			Form {
				TextEditor(text: $newState.stringContent)
					.border(.gray, width: 1)
				
				Picker("Content Type", selection: $newState.mediaType) {
					Text("Markdown").tag(MediaType.text(.markdown))
					Text("Plain text").tag(MediaType.text(.plain))
					Text("HTML").tag(MediaType.text(.html))
					Text("JSON").tag(MediaType.application(.json))
					Text("JavaScript").tag(MediaType.application(.javascript))
				}.pickerStyle(.menu)
				
				if let content = newState.content {
					Text(content.id.objectStorageKey)
						.onTapGesture {
							UIPasteboard.general.url = vm.collectedPressURL(contentID: content.id)
						}
				
					ItemView.DigestSymbolView(digestHex: content.id.sha256DigestHex)
					
					Button("Create") {
						Task {
							await vm.createPublicReadable(content: content)
						}
					}
				}
			}
		}
	}
	
	@MainActor
	struct Drop : DropDelegate {
		let vm: BucketViewModel
		
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
							Task { [vm] in
								await vm.createPublicReadable(content: content)
							}
							count += 1
						}
					})
				}
			}
			
			return count > 0
		}
	}
}

struct BucketView: View {
	@ObservedObject var vm: BucketViewModel
	
	init(bucketSource: BucketSource) {
		self.vm = BucketViewModel(bucketSource: bucketSource)
	}
	
	struct Loader: View {
		let storesSource: StoresSource
		let bucketName: String
		
		@State var loaded: Result<BucketSource, Error>?
		
		private struct TaskID: Equatable {
			let storesSourceIdentifier: ObjectIdentifier
			let bucketName: String
		}
		private var taskID: TaskID {
			TaskID(storesSourceIdentifier: ObjectIdentifier(storesSource), bucketName: bucketName)
		}
		
		var body: some View {
			Group {
				switch loaded {
				case .some(.success(let value)):
					BucketView(bucketSource: value)
				case .some(.failure(let error)):
					Text("Error loading \(error.localizedDescription)")
				case .none:
					Text("Listing bucket…")
				}
			}
				.task(id: taskID) {
					do {
						print("BucketView.Loader.task \(taskID)")
						self.loaded = .success(try await storesSource.bucketInCorrectedRegion(name: bucketName))
					}
					catch (let error) {
						self.loaded = .failure(error)
					}
				}
		}
		
//		var body: some View {
//			AsyncObjectView(loader: { () -> BucketSource in
//				let _ = print("BucketView.Loader")
//				return try await storesSource.bucketInCorrectedRegion(name: bucketName)
//			}) { result in
//				switch result {
//				case .some(.success(let value)):
//					BucketView(bucketSource: value)
//				case .some(.failure(let error)):
//					Text("Error loading \(error.localizedDescription)")
//				case .none:
//					Text("Listing bucket…")
//				}
//			}
//		}
	}
	
	enum Filter : String {
		case all
		case text
		case image
		case pdf
	}
	
	@State var filter: Filter = .all
	
	private var bucketName: String { vm.bucketName }
	
	var objects: [BucketViewModel.Object]? {
		print("use \(filter) \(ObjectIdentifier(vm))")
		switch filter {
		case .text:
			return vm.textObjects
		case .image:
			return vm.imageObjects
		case .pdf:
			return vm.pdfObjects
		case .all:
			print("use all objects \(vm.objects != nil)")
			return vm.objects
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
	
	func loadChild(key: String) async throws -> (mediaType: MediaType, contentData: Data)? {
		return try await vm.downloadObject(key: key)
	}
	
	func child(key: String) -> some View {
		AsyncView(loader: { return try await loadChild(key: key) }, content: { result in
			switch result {
			case .some(.success(let value)):
				if let value = value {
					ContentPreview.PreviewView(mediaType: value.mediaType, contentData: value.contentData)
					//						Text("Loaded! \(value.contentData.count)")
				} else {
					Text("No data")
				}
			case .some(.failure(let error)):
				Text("Error loading \(error.localizedDescription)")
			case .none:
				Text("Loading…")
			}
		})
	}
	
	var body: some View {
		VStack {
			Picker("Filter", selection: $filter) {
				Text("Images").tag(Filter.image)
				Text("Texts").tag(Filter.text)
				Text("PDFs").tag(Filter.pdf)
				Text("All").tag(Filter.all)
            }.pickerStyle(.segmented)
			
			if let error = vm.error {
				Text("Error: \(error.localizedDescription)")
			}
			
			BucketInfoView(bucketViewModel: vm)
            
			if let objects = objects {
				List {
					ForEach(objects, id: \.key) { object in
	//					NavigationLink(destination: ObjectInfoView(object: object, objectSource: bucketSource.useObject(key: object.key ?? ""))) {
						NavigationLink(destination: child(key: object.key)) {
							HStack {
								ItemView(key: object.key)
									.contextMenu {
										Button("Make Public Readable") {
											Task {
												await vm.makePublicReadable(key: object.key)
											}
										}
										Button("Delete") {
											Task {
												await vm.delete(key: object.key)
												await reload()
											}
										}
									}
								Spacer()
								Text(ByteCountFormatter.string(fromByteCount: object.size, countStyle: .file))
							}
						}
					}
					.onDelete { (indexSet) in
						guard let objects = self.objects else { return }
							
						for index in indexSet {
							let object = objects[index]
							print("DELETE!", object.key)
							Task {
								await vm.delete(key: object.key)
								await reload()
							}
						}
					}
				}
			} else {
				VStack {
					ProgressView()
					Spacer()
				}
			}
			
            NavigationLink(destination: NewBucketObjectFormView(vm: vm)) {
                Text("Create")
            }
		}
		.navigationBarTitle(bucketName)
		.task(id: ObjectIdentifier(vm)) {
//		.task {
			print(".task")
			await reload()
		}
		.onChange(of: filter) { filter in
			print(".onChange")
			Task {
				await reload(filter: filter)
			}
		}
	}
	
	@MainActor
	func reload(filter: Filter) async {
		print("reload() \(filter) \(ObjectIdentifier(vm))")
		switch filter {
		case .all:
			await vm.load()
		case .text:
			await vm.loadTexts()
		case .image:
			await vm.loadImages()
		case .pdf:
			await vm.loadPDFs()
		}
	}
	
	@MainActor
	func reload() async {
		await reload(filter: filter)
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
						Image(systemName: symbols[index])
							.font(.title)
							.foregroundColor(colors[index])
							.rotationEffect(index % 2 == 0 ? .zero : .degrees(180))
					}
				}
			} else {
				Text(digestHex).font(.caption)
			}
		}
	}
}

struct ObjectInfoView: View {
	var object: S3.Object
	@ObservedObject var objectSource: S3ObjectSource
	
	var validContent: (mediaType: MediaType, contentData: Data)? {
		if
			case let .success(output) = objectSource.getResult,
			let mediaType = output.contentType,
			let contentData = output.body?.asData() {
			return (MediaType(string: mediaType), contentData)
		} else {
			return nil
		}
	}
	
	var body: some View {
		return VStack {
			Button(action: load) { Text("Load") }
            
            if let collectedPressURL = objectSource.collectedPressURL {
				Button("Copy Collected.Press URL") {
                    UIPasteboard.general.url = collectedPressURL
                }
            }
			
			VStack {
				if let (mediaType, contentData) = validContent {
					ContentPreview.PreviewView(mediaType: mediaType, contentData: contentData)
				}
				else {
					Text("HAS NO PREVIEW")
				}
			}
		}
		.navigationBarTitle("\(objectSource.objectKey)", displayMode: .inline)
		.onAppear(perform: load)
	}
	
	private func load() {
		objectSource.load()
	}
}
