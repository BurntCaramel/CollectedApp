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
		
		super.init(coder: decoder, rootView: SettingsView(settingsSource: nil))
	}
	
	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)
		
		self.rootView = SettingsView(settingsSource: settingsSource)
	}
	
	override func viewWillDisappear(_ animated: Bool) {
		print("HIDING!!!!!")
		
		self.rootView = SettingsView(settingsSource: nil)
		self.view.setNeedsLayout()
		
		super.viewWillDisappear(animated)
	}
}

struct SettingsView: View {
	var settingsSource: Settings.Source?
	
	@ViewBuilder
	var body: some View {
		if let settingsSource = settingsSource {
			VStack {
				NavigationView {
					List {
						NavigationLink(destination: AWSSettingsView(settingsSource: settingsSource)) {
							Text("AWS")
						}
						
						NavigationLink(destination: Text("Coming soon")) {
							Text("Google Cloud")
						}
					}
				}
			}
		} else {
			Text("Loading")
		}
	}
}

struct AWSSettingsView: View {
	@ObservedObject var settingsSource: Settings.Source
	
	var body: some View {
		return Form {
			Section {
				TextField("Access Key ID", text: self.$settingsSource.awsCredentials.accessKeyID)
				TextField("Secret Access Key", text: self.$settingsSource.awsCredentials.secretAccessKey)
			}
			Button("Save", action: settingsSource.store)
		}
		.navigationBarTitle("AWS Credentials")
	}
}
