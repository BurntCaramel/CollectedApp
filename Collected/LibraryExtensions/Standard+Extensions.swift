//
//  Standard+Extensions.swift
//  Collected
//
//  Created by Patrick Smith on 24/3/2022.
//  Copyright © 2022 Patrick Smith. All rights reserved.
//

import Foundation

extension Result {
	init(work: () async throws -> Success) async {
		do {
			let success = try await work()
			self = .success(success)
		}
		catch let error as Failure {
			self = .failure(error)
		}
		catch {
			fatalError("Expected error only of type \(Failure.self)")
		}
	}
}
