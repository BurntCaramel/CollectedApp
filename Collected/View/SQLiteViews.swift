//
//  SQLiteViews.swift
//  Collected
//
//  Created by Patrick Smith on 18/3/2022.
//  Copyright © 2022 Patrick Smith. All rights reserved.
//

import Foundation
import SwiftUI
import SotoS3

struct BucketObjectSqliteView: View {
	@MainActor
	class Model: ObservableObject {
		private var opened = false
		private var connection: Database.Connection
		
		@Published var tableNames: [String]?
		@Published var exported: Data?
		@Published var outputs: [Database.Statement.ExecutionOutput] = []
//		var lastError: Error? {
//			guard let result = results.last else { return nil }
//		}
		
		init(databaseData: Data?) {
			if let databaseData = databaseData {
				connection = Database.Connection(store: .deserialize(data: databaseData))
				exported = databaseData
			} else {
				connection = Database.Connection(store: .memory)
			}
		}
		
		func open() async {
			guard opened == false else { return }
			try? await connection.open()
			opened = true
			
			await refresh()
		}
		
		func execute(sql: String) async {
			await execute(Database.Statement(sql: sql))
		}
		
		func execute(_ statement: Database.Statement, with bindings: [Database.Statement.Binding] = []) async {
			let output = await connection.queryStrings(statement, bindings: bindings)
			outputs.append(output)
			
			await refresh()
		}
		
		private func refresh() async {
			do {
				let output = await connection.queryStrings("SELECT name FROM sqlite_master WHERE type = 'table'")
				tableNames = try output.result.get().rows.compactMap({
					guard let first = $0.first else { return nil }
					return first
				})
			} catch let error {
				print(error)
			}
		}
		
		func export() async {
			exported = await connection.data
		}
		
		struct Querier {
			let connection: Database.Connection
			
			func execute(_ statement: Database.Statement, with bindings: [Database.Statement.Binding] = []) async -> Database.Statement.ExecutionOutput {
				return await connection.queryStrings(statement, bindings: bindings)
			}
		}
		
		var querier: Querier {
			.init(connection: connection)
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
		VStack(alignment: .leading, spacing: 20) {
			TextEditor(text: $statements)
				.border(.gray, width: 1)
				.disableAutocorrection(true)
				.submitLabel(.go)
				.onSubmit {
					Task {
						await model.execute(sql: statements)
					}
				}
			
			HStack {
				Button("Run") {
					Task {
						await model.execute(sql: statements)
					}
				}
				.keyboardShortcut(.defaultAction)
				
				Spacer()
				
				Menu {
					Button("SQLite Version", action: querySQLiteVersion)
					Button("Current Date & Time", action: queryDatetime)
					Button("Debug Tables", action: queryDebugTables)
					Divider()
					Button("Create SQLite Archive table", action: createSQLLiteArchiveTable)
					
				} label: {
					Label("Quickly Run", systemImage: "ellipsis.circle")
				}
				.frame(maxWidth: 120)
			}
			
			List {
				ForEach(model.outputs.indices.lazy.reversed(), id: \.self) { index in
					let output = model.outputs[index]
					OutputItem(index: index, output: output)
				}
			}
			.listStyle(.plain)
			.padding(0)
			
			if let tableNames = model.tableNames {
				Section("Tables") {
					List {
						ForEach(tableNames, id: \.self) { tableName in
							NavigationLink(tableName, destination: TableView(tableName: tableName, querier: model.querier))
						}
					}
					.listStyle(.plain)
					.padding(0)
				}
			}
			
			if let exported = model.exported {
				NavigationLink(destination: DatabaseDump(data: exported)) {
					Text("View Snapshot Data")
				}
			}
		}
		.padding()
		.task {
			await model.open()
		}
		.toolbar {
			Button("Snapshot", action: snapshot)
			Button("Upload to S3", action: upload)
		}
		.navigationTitle("SQLite")
	}
	
	private func execute(sql: String) {
		Task {
			await model.execute(sql: sql)
		}
	}
	
	func querySQLiteVersion() {
		execute(sql: "select sqlite_version()")
	}
	
	func queryDatetime() {
		execute(sql: "select datetime()")
	}
	
	func queryDebugTables() {
		execute(sql: "SELECT * FROM sqlite_master WHERE type = 'table'")
	}
	
	func createSQLLiteArchiveTable() {
		execute(sql: "CREATE TABLE sqlar(name TEXT PRIMARY KEY, mode INT, mtime INT, sz INT, data BLOB)")
	}
	
	func snapshot() {
		Task {
			await model.export()
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
	
	struct OutputItem: View {
		let index: Int
		let output: Database.Statement.ExecutionOutput
		
		var body: some View {
			DisclosureGroup {
				Text(output.input.statement.sql)
					.font(.system(.body, design: .monospaced))
			} label: {
				Text("\(index + 1)")
					.fontWeight(.bold)
					.foregroundColor(.gray)
					.frame(minWidth: 40, alignment: .center)
				
				switch output.result {
				case .success(let result):
					LazyVGrid(
						columns: result.columnNames.map { _ in
							GridItem(.flexible(minimum: 10, maximum: 200), spacing: 4, alignment: .leading)
						},
						alignment: .leading,
						spacing: 8
					) {
						ForEach(result.columnNames.indices, id: \.self) { column in
							Text(result.columnNames[column]).fontWeight(.bold)
								.id(-1 * (column + 1))
						}
						
						ForEach(result.rows.indices, id: \.self) { row in
							ForEach(result.rows[row].indices, id: \.self) { column in
								let value = result.rows[row][column]
								Text(value ?? "null")
									.opacity(value == nil ? 0.5 : 1)
									.id(row * result.columnNames.count + column)
							}
						}
					}
					.layoutPriority(1)
					
				case .failure(let error):
					Text(error.localizedDescription)
						.foregroundColor(.red)
				}
			}
		}
	}
	
	struct DatabaseDump: View {
		let data: Data
		
		var body: some View {
			let content = ContentResource(data: data, mediaType: .application(.sqlite3))
			Text(content.id.objectStorageKey)
			
			ByteCountView(byteCount: Int64(data.count))
			
//					ScrollView {
//						LazyVGrid(columns: [GridItem(.adaptive(minimum: 10, maximum: 10), spacing: 8, alignment: .topLeading)]) {
//							ForEach(exported.indices, id: \.self) { index in
//								Text("\(index)")
//							}
//						}
//					}
			
			ScrollView {
				Text(data.map({ String(format:"%02x", $0) }).joined())
					.font(.system(.body, design: .monospaced))
					.textSelection(.enabled)
			}
		}
	}
	
	struct TableView: View {
		let tableName: String
		let querier: Model.Querier
		@State private var tableInfoResult: Result<TableInfo, Database.Error>?
		
		var body: some View {
			Group {
				switch tableInfoResult {
				case .none:
					Text("Loading…")
				case .success(let tableInfo):
					Section("Schema") {
						List {
							ForEach(0..<tableInfo.columnCount, id: \.self) { column in
								HStack {
									let (name, type) = tableInfo[column: column]
									Text(name).fontWeight(.bold)
									Spacer()
									Text(type)
								}
							}
						}
					}
				case .failure(let error):
					Text("Error \(error.localizedDescription)")
				}
			}
			.task {
				Task {
					tableInfoResult = await Result(work: {
						return try await TableInfo(tableName: tableName, querier: querier)
					})
				}
			}
			.navigationTitle("Table \(tableName)")
		}
		
		struct TableInfo {
			private var output: Database.Statement.ExecutionSuccessfulOutput
			
			init(tableName: String, querier: Model.Querier) async throws {
				let output = await querier.execute("select cid, pk, name, type, 'notnull' from pragma_table_info(?)", with: [.string(tableName)])
				self.output = try output.result.get()
			}
			
			var columnCount: Int {
				output.rows.count
			}
			
			subscript(column column: Int) -> (name: String, type: String) {
				let name = output.rows[column][2]!
				let type = output.rows[column][3]!
				return (name: name, type: type)
			}
		}
	}
}

struct ContentView_Previews: PreviewProvider {
	static var previews: some View {
		BucketObjectSqliteView(bucketViewModel: BucketViewModel(bucketSource: BucketSource.local()))
			.previewDevice("iPhone 8")
			.previewLayout(PreviewLayout.device)
			.padding()
			.previewDisplayName("iPhone 8")
	}
}
