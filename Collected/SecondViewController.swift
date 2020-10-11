//
//  SecondViewController.swift
//  Collected
//
//  Created by Patrick Smith on 8/9/20.
//  Copyright © 2020 Patrick Smith. All rights reserved.
//

import UIKit
import SwiftUI
import Combine
import Security

class SecondViewController: UIViewController {
	override func viewDidLoad() {
		super.viewDidLoad()
	}
}

class SettingsHostingController: UIHostingController<SettingsView> {
	var settingsSource = Settings.Source()
	
	required init?(coder decoder: NSCoder) {
		settingsSource.load()
		
		super.init(coder: decoder, rootView: SettingsView(settingsSource: settingsSource))
	}
}

struct SettingsView: View {
	@ObservedObject var settingsSource: Settings.Source
	
	var awsFormView: some View {
		Form {
			Section {
				TextField("Access Key ID", text: self.$settingsSource.awsCredentials.accessKeyID)
				TextField("Secret Access Key", text: self.$settingsSource.awsCredentials.secretAccessKey)
			}
			Button("Save", action: settingsSource.store)
		}
	}
	
	var body: some View {
		return VStack {
			Text("Settings")
			awsFormView
		}
		.environmentObject(settingsSource)
	}
}
