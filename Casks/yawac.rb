cask "yawac" do
  version "0.9.31"
  sha256 "4c7e1e5a117b5a104c78196d2d814ac10dd3f7efd4e37ad8b31f9a64e07773b3"

  url "https://github.com/vadika/yawac/releases/download/v#{version}/yawac-#{version}.zip"
  name "yawac"
  desc "Yet Another WhatsApp Client — native macOS SwiftUI"
  homepage "https://github.com/vadika/yawac"

  depends_on macos: ">= :sonoma"

  app "yawac.app"

  # Ad-hoc signed builds are quarantined by macOS Gatekeeper on first
  # launch. Strip the quarantine bit so the app opens normally.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/yawac.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/yawac",
    "~/Library/Preferences/dev.vadikas.yawac.plist",
    "~/Library/Caches/dev.vadikas.yawac",
  ]
end
