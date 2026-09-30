#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/glass-probe/GlassProbe.app
cat > build/glass-probe/Probe.swift <<'SWIFT'
import UIKit

@main
final class ProbeDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    window = UIWindow(frame: UIScreen.main.bounds)
    window?.rootViewController = ProbeVC()
    window?.makeKeyAndVisible()
    return true
  }
}

final class ProbeVC: UIViewController {
  private var effects: [UIVisualEffectView] = []
  private var mounted = false
  private let gradient = CAGradientLayer()
  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    gradient.colors = [UIColor.systemTeal.cgColor, UIColor.darkGray.cgColor, UIColor.systemOrange.cgColor]
    view.layer.addSublayer(gradient)
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    gradient.frame = view.bounds
  }
  func label(_ text: String, y: CGFloat) {
    let label = UILabel(frame: CGRect(x: 20, y: y, width: 370, height: 30))
    label.font = .systemFont(ofSize: 16)
    label.textColor = .white
    label.text = text
    view.addSubview(label)
  }
  func row(in parent: UIView, y: CGFloat, deferred: Bool) {
    for index in 0..<3 {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      if index == 1 { glass.tintColor = .white }
      let effect: UIVisualEffect = index == 2 ? UIBlurEffect(style: .systemMaterial) : glass
      let material = UIVisualEffectView(effect: deferred ? UIVisualEffect() : effect)
      material.frame = CGRect(x: CGFloat(20 + index * 125), y: y, width: 115, height: 50)
      material.cornerConfiguration = .capsule()
      parent.addSubview(material)
      let text = UILabel(frame: material.bounds)
      text.text = ["Glass", "Tinted", "Blur"][index]
      text.textAlignment = .center
      text.textColor = .white
      material.contentView.addSubview(text)
      effects.append(material)
      if deferred {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          parent.layoutIfNeeded()
          material.effect = effect
        }
      }
    }
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !mounted else { return }
    mounted = true
    print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString), reduceTransparency: \(UIAccessibility.isReduceTransparencyEnabled)")
    label("Visible root: native glass / tint / blur", y: 75)
    row(in: view, y: 115, deferred: false)
    label("Assigned after visible layout", y: 195)
    row(in: view, y: 235, deferred: true)
    label("Inside a native table header", y: 315)
    let table = UITableView(frame: CGRect(x: 0, y: 355, width: view.bounds.width, height: 100))
    table.backgroundColor = .clear
    table.isOpaque = false
    let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 80))
    table.tableHeaderView = header
    view.addSubview(table)
    row(in: header, y: 5, deferred: true)
    label("System glass buttons", y: 465)
    for index in 0..<2 {
      let button = UIButton(type: .system)
      button.configuration = index == 0 ? .glass() : .prominentGlass()
      button.configuration?.title = index == 0 ? "Regular" : "Prominent"
      button.frame = CGRect(x: CGFloat(20 + index * 185), y: 505, width: 165, height: 50)
      view.addSubview(button)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
      self.view.alpha = 0
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.view.alpha = 1 }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 17) {
      for material in self.effects {
        let effect = material.effect
        material.effect = UIVisualEffect()
        material.effect = effect
      }
    }
  }
}
SWIFT
cat > build/glass-probe/GlassProbe.app/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.native.glassprobe</string>
<key>CFBundleExecutable</key><string>GlassProbe</string>
<key>CFBundleName</key><string>GlassProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>26.0</string>
<key>LSRequiresIPhoneOS</key><true/>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UILaunchScreen</key><dict/>
</dict></plist>
PLIST
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -parse-as-library -sdk "$sdk" -target arm64-apple-ios26.0-simulator -framework UIKit build/glass-probe/Probe.swift -o build/glass-probe/GlassProbe.app/GlassProbe
codesign --force --sign - build/glass-probe/GlassProbe.app
device_id=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next(d["udid"] for r,ds in json.load(sys.stdin)["devices"].items() if "iOS-26" in r for d in ds if d["name"].startswith("iPhone")))')
xcrun simctl boot "$device_id" || true
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" build/glass-probe/GlassProbe.app
xcrun simctl launch --stdout="$PWD/build/glass-probe/probe.stdout.log" --stderr="$PWD/build/glass-probe/probe.stderr.log" "$device_id" test.native.glassprobe
sleep 5
xcrun simctl io "$device_id" screenshot build/glass-probe/1-fresh.png
sleep 9
xcrun simctl io "$device_id" screenshot build/glass-probe/2-after-alpha.png
sleep 8
xcrun simctl io "$device_id" screenshot build/glass-probe/3-reinstalled.png
