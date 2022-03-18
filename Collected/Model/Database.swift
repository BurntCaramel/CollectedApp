//
//  Database.swift
//  Collected
//
//  Created by Patrick Smith on 16/3/2022.
//  Copyright © 2022 Patrick Smith. All rights reserved.
//

import Foundation
import SQLite3

enum Database {
	enum Error : Swift.Error {
		case couldNotOpenDatabase(String?)
		case couldNotPrepareStatement(String?)
		case couldNotExecuteStatement(String?)
	}
	
	enum DatabaseStore {
		case memory
		case deserialize(data: Data)
	}
	
	actor Connection {
		let store: DatabaseStore
		private var db: OpaquePointer? = nil;
		
		init(store: DatabaseStore) {
			self.store = store
		}
		
		func open() throws {
			switch store {
			case .memory:
				guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
					throw Error.couldNotOpenDatabase(errorMessage)
				}
			case .deserialize(let data):
				let count = sqlite3_uint64(data.count)
				guard let pData = sqlite3_malloc64(count) else {
					throw Error.couldNotOpenDatabase(errorMessage)
				}
				let mutableBuffer = pData.assumingMemoryBound(to: UInt8.self)
				data.copyBytes(to: mutableBuffer, count: data.count)
				guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
					throw Error.couldNotOpenDatabase(errorMessage)
				}
//				sqlite3_deserialize(db, "main", pData, sqlite3_int64(count), sqlite3_int64(count), UInt32(SQLITE_DESERIALIZE_RESIZEABLE | SQLITE_DESERIALIZE_FREEONCLOSE))
				sqlite3_deserialize(db, "main", pData, sqlite3_int64(count), sqlite3_int64(count), UInt32(SQLITE_DESERIALIZE_READONLY))
				
//				data.withUnsafeMutableBytes { buffer in
//					if let baseAddress = buffer.baseAddress {
////						sqlite3_deserialize(db, "main", baseAddress, count, count, UInt32(SQLITE_DESERIALIZE_READONLY))
//						sqlite3_deserialize(db, "main", baseAddress, sqlite3_int64(count), sqlite3_int64(count), 0)
//					}
//				}
			}
		}
		
		func close() {
			sqlite3_close_v2(db)
			db = nil
		}
		
		fileprivate static func errorMessage(db: OpaquePointer?) -> String? {
			guard let pointer = sqlite3_errmsg(db) else { return nil }
			
			return String(cString: pointer)
		}
		
		var errorMessage: String? {
			guard let pointer = sqlite3_errmsg(db) else { return nil }
			
			return String(cString: pointer)
		}
		
		var data: Data? {
			switch store {
			case .memory:
				var size: sqlite3_int64 = 0
//				let pointer = sqlite3_serialize(db, "main", &size, UInt32(SQLITE_SERIALIZE_NOCOPY))
				let pointer = sqlite3_serialize(db, "main", &size, 0)
				guard let pointer = pointer else { return nil }
				defer { sqlite3_free(pointer) }
//				let buffer = UnsafeRawBufferPointer(start: pointer, count: Int(size))
//				let buffer = UnsafeRawBufferPointer(start: pointer, count: Int(size))
//				buffer.baseAddress
//				let buffer8Bit = buffer.bindMemory(to: UInt8.self)
				let data = Data(bytes: pointer, count: Int(size))
				return data
				
//				sqlite3_backup_init(<#T##pDest: OpaquePointer!##OpaquePointer!#>, "main", &db, "main")
//				sqlite3_backup_step(&db, -1)
//				sqlite3_backup_finish(&db)
			case .deserialize(let data):
				return data
			}
		}
		
		func vacuum() throws {
//			sqlite3_autovacuum_pages(<#T##db: OpaquePointer!##OpaquePointer!#>, <#T##((UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt32, UInt32, UInt32) -> UInt32)!##((UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt32, UInt32, UInt32) -> UInt32)!##(UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt32, UInt32, UInt32) -> UInt32#>, <#T##UnsafeMutableRawPointer!#>, <#T##((UnsafeMutableRawPointer?) -> Void)!##((UnsafeMutableRawPointer?) -> Void)!##(UnsafeMutableRawPointer?) -> Void#>)
		}
	}
	
	struct Statement : Sendable {
		var sql: String
	}
}

extension Database.Statement : ExpressibleByStringLiteral {
	init(stringLiteral value: StringLiteralType) {
		self.sql = value
	}
}

extension Database.Connection {
	enum StatementBinding : ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
		case int32(_ value: Int32)
		case string(_ value: String)
		
		func apply(statementInstance: OpaquePointer, offset: Int32) {
			switch self {
			case .int32(let value):
				sqlite3_bind_int(statementInstance, offset, value)
			case .string(let value):
				sqlite3_bind_text(statementInstance, offset, (value as NSString).utf8String, -1, nil)
			}
		}
		
		init(stringLiteral value: StringLiteralType) {
			self = .string(value)
		}
		
		init(integerLiteral value: IntegerLiteralType) {
			self = .int32(Int32(value))
		}
	}
	
	struct StatementExecution {
		private let db: OpaquePointer?;
		private let conn: Database.Connection
		private let statementInstance: OpaquePointer;
		
		init(statement: Database.Statement, conn: isolated Database.Connection, bindings: [StatementBinding]) throws {
			self.conn = conn
			self.db = conn.db
			
			var statementInstance: OpaquePointer? = nil;
			guard sqlite3_prepare_v2(conn.db, statement.sql, -1, &statementInstance, nil) == SQLITE_OK, let statementInstance = statementInstance else {
				print("couldNotPrepareStatement")
				print(String(cString: sqlite3_errmsg(conn.db)))
				throw Database.Error.couldNotPrepareStatement(conn.errorMessage)
			}
			
			for (index, binding) in bindings.enumerated() {
				binding.apply(statementInstance: statementInstance, offset: Int32(index + 1))
			}
			
			self.statementInstance = statementInstance
		}
		
		func close() {
			sqlite3_finalize(statementInstance)
		}
		
		private var errorMessage: String? {
			return Database.Connection.errorMessage(db: db)
		}
		
		func singleStep() throws {
			guard sqlite3_step(statementInstance) == SQLITE_DONE else {
//				sqlite3_errmsg(conn.db)
				throw Database.Error.couldNotExecuteStatement(errorMessage)
			}
		}
		
		func nextRow() -> Bool {
			guard sqlite3_step(statementInstance) == SQLITE_ROW else {
				return false
			}
			
			return true
		}
		
		subscript(columnName column: Int32) -> String? {
			guard let pointer = sqlite3_column_name(statementInstance, column) else { return nil }
			return String(cString: pointer)
		}
		
		subscript(int column: Int32) -> Int32 {
			return sqlite3_column_int(statementInstance, column)
		}
		
		subscript(string column: Int32) -> String? {
			guard let pointer = sqlite3_column_text(statementInstance, column) else { return nil }
			return String(cString: pointer)
		}
		
		func columnNames() -> [String] {
			let count = sqlite3_column_count(statementInstance)
			print("col count \(count)")
			return (0..<count).map {
				String(cString: sqlite3_column_name(statementInstance, $0))
			}
		}
		
		func valuesText() -> [String] {
			let count = sqlite3_data_count(statementInstance)
			return (0..<count).map {
				if let pointer = sqlite3_column_text(statementInstance, $0) {
					return String(cString: pointer)
				} else {
					return "[nil]"
				}
			}
		}
	}
	
	func execute(_ statement: Database.Statement, bindings: StatementBinding...) throws {
		let execution = try StatementExecution(statement: statement, conn: self, bindings: bindings)
		defer {
			execution.close()
		}
		
		try execution.singleStep()
	}
	
	func queryInt32(_ statement: Database.Statement, bindings: StatementBinding...) throws -> Int32 {
		let execution = try StatementExecution(statement: statement, conn: self, bindings: bindings)
		defer {
			execution.close()
		}
		
		try execution.nextRow()
		return execution[int: 0]
	}
	
	func queryString(_ statement: Database.Statement, bindings: StatementBinding...) throws -> String? {
		let execution = try StatementExecution(statement: statement, conn: self, bindings: bindings)
		defer {
			execution.close()
		}
		
		try execution.nextRow()
		return execution[string: 0]
	}
	
	func queryStrings(_ statement: Database.Statement, bindings: StatementBinding...) throws -> (columnNames: [String], firstRow: [String]) {
		let execution = try StatementExecution(statement: statement, conn: self, bindings: bindings)
		defer {
			execution.close()
		}
		
		print("COLUMN NAMES")
		print(execution.columnNames())
		
		let columnNames = execution.columnNames()
		try execution.nextRow()
		let firstRow = execution.valuesText()
		return (columnNames: columnNames, firstRow: firstRow)
	}
	
	func nextRow(execution: StatementExecution) -> [String]? {
		guard try execution.nextRow() else { return nil }
		return execution.valuesText()
	}
	
	struct QueryIterable : AsyncSequence, AsyncIteratorProtocol {
		typealias Element = [String]
		
		private let conn: Database.Connection
		private let statement: Database.Statement
		private let bindings: [StatementBinding]
		private var execution: StatementExecution?
		
		init(conn: Database.Connection, statement: Database.Statement, bindings: [StatementBinding]) {
			self.conn = conn
			self.statement = statement
			self.bindings = bindings
		}
		
		mutating func next() async throws -> [String]? {
			try Task.checkCancellation()
			
			if let execution = execution {
				return await conn.nextRow(execution: execution)
			}
			
			let execution = try await StatementExecution(statement: statement, conn: conn, bindings: bindings)
			defer {
				self.execution = execution
			}
			return await conn.nextRow(execution: execution)
			//            await withTaskCancellationHandler(operation: {
			//                await self.conn.nextRow(execution: self.execution)
			//            }, onCancel: {
			//                execution.close()
			//            })
		}
		
		func makeAsyncIterator() -> QueryIterable {
			self
		}
	}
	
	nonisolated func queryRowsText(_ statement: Database.Statement, bindings: StatementBinding...) -> QueryIterable {
		return QueryIterable(conn: self, statement: statement, bindings: bindings)
	}
}

protocol SQLite3Convertible {
	static var sqlite3RawType: (datatype: String, nullable: Bool) { get }
}

extension Int32 : SQLite3Convertible {
	static var sqlite3RawType: (datatype: String, nullable: Bool) { ("INT", false) }
}

extension String : SQLite3Convertible {
	static var sqlite3RawType: (datatype: String, nullable: Bool) { ("TEXT", false) }
}

extension Optional : SQLite3Convertible where Wrapped == String {
	static var sqlite3RawType: (datatype: String, nullable: Bool) { ("TEXT", true) }
}

extension KeyPath : SQLite3Convertible where Value: SQLite3Convertible {
	static var sqlite3RawType: (datatype: String, nullable: Bool) { Value.sqlite3RawType }
}

extension Database.Connection {
	func createTable<Definition, PrimaryKey>(tableName: String, primaryKey: KeyPath<Definition, PrimaryKey>) throws where PrimaryKey : SQLite3Convertible {
		let (primaryKeyType, _) = PrimaryKey.sqlite3RawType
		print(Database.Statement(sql: """
CREATE TABLE \(tableName)(
Id \(primaryKeyType) PRIMARY KEY NOT NULL,
Name CHAR(255));
"""))
	}
}

//struct Example {
//	var primary: Int32
//}
//
//let group = DispatchGroup()
//group.enter()
//
//let task = Task.detached {
//	print("Running")
//	defer { group.leave() }
//
//	let conn = try Database.Connection()
//	try await conn.execute("""
//CREATE TABLE Contact(
//Id INT PRIMARY KEY NOT NULL,
//Name CHAR(255));
//""")
//	print("created table")
//
//	try await conn.createTable(tableName: "Blah", primaryKey: \Example.primary)
//
//	let count1 = try await conn.queryInt32("SELECT COUNT(*) FROM Contact;")
//	print(count1)
//
//	try await conn.execute("INSERT INTO Contact (Id, Name) VALUES (?, ?);", bindings: 7, "Jane Doe")
//	try await conn.execute("INSERT INTO Contact (Id, Name) VALUES (?, ?);", bindings: 8, "Alice")
//	print("inserted rows")
//
//	let count2 = try await conn.queryString("SELECT COUNT(*) FROM Contact;")
//	print(count2)
//
//	print("All rows")
//	for try await values in conn.queryRowsText("SELECT * FROM Contact;") {
//		print(values)
//	}
//	//    print(try await conn.queryStrings("SELECT * FROM Contact;"))
//}
//
//group.wait()

