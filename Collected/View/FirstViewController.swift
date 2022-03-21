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
import WebKit
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
					.listStyle(.sidebar)
				}
			}
			.navigationTitle("Buckets")
		}
	}
}

struct NewBucketObjectFormView: View {
	@StateObject var vm: BucketViewModel
	
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
			.background(isDropActive ? Color.green : Color.yellow)
			.onDrop(of: [UTType.text, UTType.image, UTType.pdf], delegate: Drop(vm: vm))
			
			Picker("Content Type", selection: $newState.mediaType) {
				Text("Markdown").tag(MediaType.text(.markdown))
				Text("Plain text").tag(MediaType.text(.plain))
				Text("HTML").tag(MediaType.text(.html))
				Text("JSON").tag(MediaType.application(.json))
				Text("JavaScript").tag(MediaType.application(.javascript))
			}
			.pickerStyle(.menu)
			.frame(maxWidth: 250)
			
			TextEditor(text: $newState.stringContent)
				.border(.gray, width: 1)
			
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
		.padding()
		.navigationTitle("Create in \(vm.bucketName)")
	}
	
	@MainActor
	struct Drop : DropDelegate {
		let vm: BucketViewModel
		
		func performDrop(info: DropInfo) -> Bool {
			var count = 0
			
			for mediaType in [MediaType.text(.plain), .text(.markdown), .text(.html), .text(.json), .application(.javascript), .image(.png), .image(.gif), .image(.jpeg), .image(.tiff), .application(.pdf), .application(.json)] {
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
	@StateObject var vm: BucketViewModel
	
	init(bucketSource: BucketSource) {
		_vm = StateObject(wrappedValue: BucketViewModel(bucketSource: bucketSource))
	}
	
	struct Loader: View {
		let storesSource: StoresSource
		let bucketName: String
		
		@State var result: Result<BucketSource, Error>?
		
		var body: some View {
			Group {
				switch result {
				case .some(.success(let value)):
					BucketView(bucketSource: value)
				case .some(.failure(let error)):
					VStack {
						let _ = print(error)
						Text("Error listing bucket \(error.localizedDescription)")
						Button("Reload", action: load)
					}
				case .none:
					Text("Listing bucket…")
				}
			}
				.task {
					load()
				}
		}
		
		func load() {
			Task {
				do {
					self.result = .success(try await storesSource.bucketInCorrectedRegion(name: bucketName))
				}
				catch (let error) {
					self.result = .failure(error)
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
	@State var searchString = ""
	
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
	
	func child(key: String) -> some View {
		AsyncView(loader: { return try await vm.downloadObject(key: key) }, content: { result in
			switch result {
			case .some(.success(let value)):
				if let mediaType = value.mediaType, let contentData = value.contentData {
					let contentID = ContentIdentifier(objectStorageKey: key)
					let collectedPressURL = contentID.map { vm.collectedPressURL(contentID: $0) }
					let collectedPressHighlightURL = contentID.map { vm.collectedPressHighlightURL(contentID: $0) }
					if value.mediaType == .application(.sqlite3) {
						NewBucketObjectSqliteView(bucketViewModel: vm, databaseData: value.contentData)
							.navigationTitle("SQLite3")
//							.navigationSubtitle(key)
					} else {
						ValidObjectInfoView(key: key, mediaType: mediaType, contentData: contentData, collectedPressURL: collectedPressURL, collectedPressPreviewURL: collectedPressHighlightURL)
					}
				} else {
					VStack {
						Text("No data")
						
						Section("Metadata") {
							List {
								ForEach(value.metadata.keys.sorted(), id: \.self) { key in
									HStack {
										Text(key)
										Text(value.metadata[key]!)
									}
								}
							}
						}
					}
				}
			case .some(.failure(let error)):
				Text("Error loading object \(error.localizedDescription)")
			case .none:
				Text("Loading…")
			}
		})
	}
	
	var body: some View {
		VStack {
			if let error = vm.error {
				Text("Error: \(error.localizedDescription)")
			}
			
			BucketInfoView(bucketViewModel: vm)
            
			if let objects = objects {
				List {
					ForEach(objects, id: \.key) { object in
						NavigationLink(destination: child(key: object.key)) {
							HStack {
								ItemView(key: object.key)
									.contextMenu {
										Button("Copy URL") {
											vm.copyURL(key: object.key)
										}
										Button("Share…") {
											let url = vm.url(key: object.key)
											let activityController = UIActivityViewController(activityItems: [url], applicationActivities: nil)
//											guard let vc = keyWindow()?.rootViewController else { return }
											guard let vc = topMostViewController() else { return }
											vc.present(activityController, animated: true, completion: nil)
										}
										Divider()
										Button("Make Public Readable") {
											Task {
												await vm.makePublicReadable(key: object.key)
											}
										}
										Button("Make Redirect…") {
											Task {
												let alert = UIAlertController(title: "title", message: "message", preferredStyle: .alert)
												alert.title = "Create redirect object"
												alert.message = "The object will redirect to \(object.key)"
												
												alert.addTextField() { textField in
													textField.placeholder = "Enter new key"
												}
												
												let cancelAction = UIAlertAction(title: "Cancel", style: .cancel) { _ in }
												alert.addAction(cancelAction)
												
												let createAction = UIAlertAction(title: "Create Redirect", style: .default) { _ in
													guard let newKey = alert.textFields?.first?.text else { return }
													print("Alert action \(newKey)")
													Task {
														await vm.createPublicReadableRedirect(key: newKey, redirectLocation: object.key)
													}
												}
												alert.addAction(createAction)
												alert.preferredAction = createAction
												
												guard let vc = topMostViewController() else { return }
												vc.present(alert, animated: true)
											}
										}
										Divider()
										Button("Delete") {
											Task {
												await vm.delete(key: object.key)
												await reload()
											}
										}
									}
								Spacer()
								ByteCountView(byteCount: object.size)
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
					.listStyle(.plain)
					.padding(0)
				}
			} else {
				VStack {
					ProgressView()
					Spacer()
				}
			}
		}
		.navigationTitle(bucketName)
//		.navigationSubtitle("Region: \(vm.region.rawValue)")
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
		.toolbar {
			Picker("Filter", selection: $filter) {
				Text("Images").tag(Filter.image)
				Text("Texts").tag(Filter.text)
				Text("PDFs").tag(Filter.pdf)
				Text("All").tag(Filter.all)
			}.pickerStyle(.segmented)
			
			Spacer()
			
			NavigationLink(destination: NewBucketObjectFormView(vm: vm)) {
				Text("Create Text")
			}
			
			NavigationLink(destination: NewBucketObjectSqliteView(bucketViewModel: vm)) {
				Text("Create SQLite")
			}
		}
//		.searchable(text: $searchString)
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
		case .application(.sqlite3): return (imageName: "tablecells", text: "sqlite", contentIdentifier: contentIdentifier)
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

struct ValidObjectInfoView: View {
	var key: String
	var mediaType: MediaType
	var contentData: Data
	var collectedPressURL: URL?
	var collectedPressPreviewURL: URL?

	var body: some View {
		VStack {
            if let collectedPressURL = collectedPressURL {
				Button("Copy Collected.Press URL") {
					let pb = UIPasteboard.general
					pb.items = [[
						UTType.plainText.identifier: collectedPressURL.absoluteString,
						UTType.url.identifier: collectedPressURL
					]]
//					pb.string = collectedPressURL.absoluteString
//                    pb.url = collectedPressURL
                }
			}
			if let collectedPressPreviewURL = collectedPressPreviewURL {
				NavigationLink(destination: WebPreview(url: collectedPressPreviewURL)) {
					Text("Collected.Press")
				}
            }

			ContentPreview.PreviewView(mediaType: mediaType, contentData: contentData)
		}
		.navigationBarTitle(key, displayMode: .inline)
	}
	
	struct WebPreview: View {
		var url: URL
		
		var body: some View {
			VStack {
				Text(url.absoluteString)
					.frame(maxWidth: .infinity)
				
				WebView(url: url)
			}
		}
	}
}

struct WebView: UIViewRepresentable {
	var url: URL
	
	// Make a coordinator to co-ordinate with WKWebView's default delegate functions
//	func makeCoordinator() -> Coordinator {
//		Coordinator(self)
//	}
	
	func makeUIView(context: Context) -> WKWebView {
		// Enable javascript in WKWebView to interact with the web app
		let preferences = WKPreferences()
//		preferences.allowsContentJavaScript = true
		
		let configuration = WKWebViewConfiguration()
		// Here "iOSNative" is our interface name that we pushed to the website that is being loaded
//		configuration.userContentController.add(self.makeCoordinator(), name: "iOSNative")
		configuration.preferences = preferences
		
		let webView = WKWebView(frame: CGRect.zero, configuration: configuration)
//		webView.navigationDelegate = context.coordinator
		webView.allowsBackForwardNavigationGestures = true
		webView.scrollView.isScrollEnabled = true
		webView.scrollView.contentInset = .zero
	   return webView
	}
	
	func updateUIView(_ webView: WKWebView, context: Context) {
		webView.load(URLRequest(url: url))
	}
}
