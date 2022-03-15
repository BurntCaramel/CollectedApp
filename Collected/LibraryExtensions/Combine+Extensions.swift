//
//  Comeine+Extensions.swift
//  Collected
//
//  Created by Patrick Smith on 27/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import Combine

extension Publisher {
	func catchAsResult() -> Publishers.Catch<Publishers.Map<Self, Result<Output, Failure>>, Just<Result<Output, Failure>>> {
		map(Result.success).catch { Just(Result.failure($0)) }
	}
}
