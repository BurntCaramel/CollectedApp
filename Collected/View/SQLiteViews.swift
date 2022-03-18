//
//  SQLiteViews.swift
//  Collected
//
//  Created by Patrick Smith on 18/3/2022.
//  Copyright © 2022 Patrick Smith. All rights reserved.
//

import Foundation
import SwiftUI

struct NewBucketObjectSqliteView: View {
	@MainActor
	class Model: ObservableObject {
		private var opened = false
		private var connection: Database.Connection
		
		@Published var tableNames: [String]?
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
			
			do {
				let result = try await connection.queryStrings(.init(sql: "SELECT name FROM sqlite_master WHERE type = 'table';"))
				tableNames = result.firstRow
			} catch {}
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
	@StateObject var bucketViewModel: BucketViewModel
	@StateObject var model: Model
	@State var statements = "create table blah(id INT PRIMARY KEY NOT NULL, name CHAR(255));"
	
	init(bucketViewModel: BucketViewModel, databaseData: Data? = nil) {
		_bucketViewModel = .init(wrappedValue: bucketViewModel)
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
					Button("SQLite Version") {
						Task {
							await model.execute(sql: "select sqlite_version();")
						}
					}
					
					Divider()
					
					Button("Create Table blah") {
						Task {
							await model.execute(sql: "create table blah(id INTEGER PRIMARY KEY NOT NULL, name CHAR(255));")
							await model.execute(sql: "insert into blah (name) values ('first');")
						}
					}
					
					Divider()
					
					Button("Create Table sqlar") {
						Task {
							await model.execute(sql: "CREATE TABLE sqlar(name TEXT PRIMARY KEY, mode INT, mtime INT, sz INT, data BLOB);")
						}
					}
				}
				
				if let tableNames = model.tableNames {
					List {
						ForEach(tableNames, id: \.self) { tableName in
							Text(tableName)
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
					
					ByteCountView(byteCount: Int64(exported.count))
					
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
			await bucketViewModel.createPublicReadable(content: content)
		}
	}
}

