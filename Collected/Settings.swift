//
//  Settings.swift
//  Collected
//
//  Created by Patrick Smith on 11/10/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import Foundation

enum Settings {
	struct AWSCredentials {
		var accessKeyID: String
		var secretAccessKey: String
		var region: String
	}
	
	class Source: ObservableObject {
		@Published var awsCredentials = Settings.AWSCredentials(accessKeyID: "", secretAccessKey: "", region: "")
		@Published var errorMessages: [String] = []
		
		var awsTag: Data { "org.RoyalIcing.Collected.keys.aws".data(using: .utf8)! }
		
		func readAWS() {
			let query: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: "AWS",
				//            kSecAttrAccount as String: awsCredentials.accessKeyID,
				//            kSecAttrSynchronizable as String: true,
				//            kSecAttrApplicationTag as String: awsTag,
				kSecReturnAttributes as String: true,
				kSecReturnData as String: true,
				kSecMatchLimit as String: kSecMatchLimitOne,
			]
			
			var queryResult: AnyObject?
			let status: OSStatus = withUnsafeMutablePointer(to: &queryResult) {
				let status = SecItemCopyMatching(query as CFDictionary, $0)
				
				print("LOADED AWS", $0.pointee, status)
				
				return status
			}
			
			if status == errSecItemNotFound {
				print("AWS credentials not found")
				//            self.awsCredentials = nil
				return
			}
			
			if status == errSecNoSuchAttr {
				print("AWS credentials loaded with incorrect attr")
				return
			}
			
			print("LOADED AWS", queryResult)
			
			guard let existingItem = queryResult as? [String : AnyObject],
						let account = existingItem[kSecAttrAccount as String] as? String,
						let passwordData = existingItem[kSecValueData as String] as? Data,
						let password = String(data: passwordData, encoding: String.Encoding.utf8)
			else {
				print("Couldn't decode AWS", queryResult)
				//                throw KeychainError.unexpectedPasswordData
				return
			}
			
			awsCredentials = .init(accessKeyID: account, secretAccessKey: password, region: "us-west-2")
			print("LOADED AWS", awsCredentials)
		}
		
		func load() {
			readAWS()
		}
		
		func store() {
			errorMessages = []
			
			print("SAVING AWS", awsCredentials)
			
			let secretData = awsCredentials.secretAccessKey.data(using: .utf8)!
			
			var query: [String: Any] = [
				kSecClass as String: kSecClassGenericPassword,
				kSecAttrService as String: "AWS",
	//			kSecAttrAccount as String: "AWS 1",
				//            kSecAttrAccount as String: awsCredentials.accessKeyID,
			]
			
			let status = SecItemCopyMatching(query as CFDictionary, nil)
			switch status {
			case errSecSuccess:
				let attributesToUpdate: [String: Any] = [
					kSecAttrAccount as String: awsCredentials.accessKeyID,
					kSecValueData as String: secretData
				]
				let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
				if status != errSecSuccess {
					print("Could not update AWS credentials", status)
					errorMessages.append("Could not save AWS credentials")
				}
			case errSecItemNotFound:
				query[kSecAttrAccount as String] = awsCredentials.accessKeyID
				query[kSecValueData as String] = secretData
				query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
				//query[kSecAttrSynchronizable as String] = true
				//query[kSecAttrApplicationTag as String] = awsTag
				
				let status = SecItemAdd(query as CFDictionary, nil)
				if status != errSecSuccess {
					print("Could not save AWS credentials", status)
					errorMessages.append("Could not save AWS credentials")
				}
			default:
				print("Could not load AWS credentials to save")
			}
			
			print("READING AGAIN")
			readAWS()
			
			//        if let awsCredentials = self.awsCredentials {
			//        }
		}
	}
}
