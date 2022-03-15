//
//  NIO+Combine.swift
//  Collected
//
//  Created by Patrick Smith on 10/9/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import NIO
import Combine

extension NIO.EventLoopFuture {
    func toCombine() -> Combine.Future<Value, Error> {
        Combine.Future(self.whenComplete)
    }
}

extension Combine.Deferred {
	public init<Value>(createNIOFuture: @escaping () -> NIO.EventLoopFuture<Value>) where DeferredPublisher == Combine.Future<Value, Error> {
		self.init(createPublisher: { createNIOFuture().toCombine() })
	}
}
