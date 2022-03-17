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

@MainActor
class BucketViewModel: ObservableObject {
	private var bucket: BucketSource
	
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
		self.bucket = bucketSource
	}
	
	var bucketName: String { bucket.bucketName }
	var region: Region { bucket.region }
	var collectedPressRootURL: URL {
		URL(string: "https://collected.press/1/s3/object/\(region.rawValue)/\(bucketName)/")!
	}
	var collectedPressRootHighlightURL: URL {
		URL(string: "https://collected.press/1/s3/highlight/\(region.rawValue)/\(bucketName)/")!
	}
	var collectedPressRootHighlightURLComponents: URLComponents {
		URLComponents(string: "https://collected.press/1/s3/highlight/\(region.rawValue)/\(bucketName)/")!
	}
	
	func collectedPressURL(contentID: ContentIdentifier) -> URL {
		collectedPressRootURL.appendingPathComponent(contentID.objectStorageKey)
	}
	func collectedPressHighlightURL(contentID: ContentIdentifier) -> URL {
		var urlComponents = collectedPressRootHighlightURLComponents
		urlComponents.path += contentID.objectStorageKey
		urlComponents.queryItems = [URLQueryItem(name: "theme", value: "1")]
		return urlComponents.url!
	}
	
	func downloadObject(key: String) async throws -> (mediaType: MediaType, contentData: Data)? {
		do {
			let output = try await bucket.getObject(key: key)
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
			let _ = try await bucket.delete(key: key)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func load() async {
		do {
			print("will reload list")
			objects = try await bucket.listAll().compactMap(Object.init)
			print("did reload list")
			loadCount += 1
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func loadImages() async {
		do {
			imageObjects = try await bucket.listImages().compactMap(Object.init)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func loadTexts() async {
		do {
			textObjects = try await bucket.listTexts().compactMap(Object.init)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func loadPDFs() async {
		do {
			pdfObjects = try await bucket.listPDFs().compactMap(Object.init)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func createPublicReadable(content: ContentResource) async {
		do {
			let _ = try await bucket.createPublicReadable(content: content)
		}
		catch (let error) {
			self.error = error
		}
	}
	
	func makePublicReadable(key: String) async {
		do {
			let _ = try await bucket.makePublicReadable(key: key)
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

struct NewBucketObjectSqliteView: View {
	@MainActor
	class Model: ObservableObject {
		private var opened = false
		private var connection: Database.Connection
		
		@Published var exported: Data?
		@Published var results: [Result<(columnNames: [String], firstRow: [String]), Database.Error>] = []
//		var lastError: Error? {
//			guard let result = results.last else { return nil }
//		}
		
		init(databaseData: Data?) {
			if let databaseData = databaseData {
				connection = Database.Connection(store: .deserialize(data: databaseData))
			} else {
				connection = Database.Connection(store: .memory)
			}
		}
		
		func open() async {
			print("OPEN DB")
			guard opened == false else { return }
			try? await connection.open()
			opened = true
		}
		
		func execute(sql: String) async {
			let statement = Database.Statement(sql: sql)
			await execute(statement: statement)
		}
		
		func execute(statement: Database.Statement) async {
			do {
				let result = try await connection.queryStrings(statement)
				results.append(.success(result))
			} catch let error as Database.Error {
				results.append(.failure(error))
//				self.lastError = error
			} catch {}
		}
		
		func export() async {
			exported = await connection.data
		}
	}
	
//	let inputDatabaseData: Data?
	@StateObject var vm: BucketViewModel
	@StateObject var model: Model
	@State var statements = "create table blah(id INT PRIMARY KEY NOT NULL, name CHAR(255));"
	
	init(vm: BucketViewModel, databaseData: Data? = nil) {
		_vm = .init(wrappedValue: vm)
		_model = .init(wrappedValue: Model(databaseData: databaseData))
	}
	
	var body: some View {
		VStack {
			Form {
				TextEditor(text: $statements)
					.border(.gray, width: 1)
					.disableAutocorrection(true)
					.submitLabel(.go)
					.onSubmit {
						Task {
							await model.execute(sql: statements)
						}
					}
				
				Button("Run") {
					Task {
						await model.execute(sql: statements)
					}
				}
				.keyboardShortcut(.defaultAction)
				
				HStack {
				Button("Create Table blah") {
					Task {
						await model.execute(sql: "create table blah(id INTEGER PRIMARY KEY NOT NULL, name CHAR(255));")
						await model.execute(sql: "insert into blah (name) values ('first');")
					}
				}
				
				Button("Create Table sqlar") {
					Task {
						await model.execute(sql: "CREATE TABLE sqlar(name TEXT PRIMARY KEY, mode INT, mtime INT, sz INT, data BLOB);")
					}
				}
				}
				
				Button("Show Tables") {
					Task {
						await model.execute(sql: "SELECT name FROM sqlite_master WHERE type = \"table\";")
					}
				}
				
				Button("Dump", action: export)
				Button("Upload to S3", action: upload)
				
				List {
					ForEach(model.results.indices.lazy.reversed(), id: \.self) { index in
						HStack {
							Text("\(index + 1)")
								.fontWeight(.bold)
								.foregroundColor(.gray)
								.frame(minWidth: 40, alignment: .leading)
							
							let result = model.results[index]
							let _ = print(result)
							switch result {
							case .success(let result):
								VStack(alignment: .leading, spacing: 4) {
									HStack {
										ForEach(result.columnNames.indices, id: \.self) { column in
											Text(result.columnNames[column]).fontWeight(.bold)
										}
									}
									HStack {
										ForEach(result.firstRow.indices, id: \.self) { column in
											Text(result.firstRow[column])
										}
									}
								}
								
							case .failure(let error):
								Text(error.localizedDescription)
									.foregroundColor(.red)
							}
						}
					}
				}
				
				if let exported = model.exported {
					let content = ContentResource(data: exported, mediaType: .application(.sqlite3))
					Text(content.id.objectStorageKey)
					
//					ScrollView {
//						LazyVGrid(columns: [GridItem(.adaptive(minimum: 10, maximum: 10), spacing: 8, alignment: .topLeading)]) {
//							ForEach(exported.indices, id: \.self) { index in
//								Text("\(index)")
//							}
//						}
//					}
					
					Text(exported.map({ String(format:"%02x", $0) }).joined())
						.font(.system(.body, design: .monospaced))
				}
			}
		}
		.task {
			await model.open()
		}
	}
	
	func export() {
		Task {
			await model.export()
			print(model.exported)
		}
	}
	
	func upload() {
		Task {
			await model.export()
			guard let exported = model.exported else { return }
			let content = ContentResource(data: exported, mediaType: .application(.sqlite3))
			await vm.createPublicReadable(content: content)
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
					Text("Error loading \(error.localizedDescription)")
				case .none:
					Text("Listing bucket…")
				}
			}
				.task {
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
				if let value = value {
					let contentID = ContentIdentifier(objectStorageKey: key)
					let collectedPressURL = contentID.map { vm.collectedPressURL(contentID: $0) }
					let collectedPressHighlightURL = contentID.map { vm.collectedPressHighlightURL(contentID: $0) }
					if value.mediaType == .application(.sqlite3) {
						NewBucketObjectSqliteView(vm: vm, databaseData: value.contentData)
							.navigationTitle("SQLite3")
							.navigationSubtitle(key)
					} else {
						ValidObjectInfoView(key: key, mediaType: value.mediaType, contentData: value.contentData, collectedPressURL: collectedPressURL, collectedPressPreviewURL: collectedPressHighlightURL)
					}
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
					.listStyle(.plain)
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
			NavigationLink(destination: NewBucketObjectSqliteView(vm: vm)) {
				Text("Create SQLite")
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
