cask "yawac" do
  version "0.9.20"
  sha256 "8960b28c0694e6fea072b6706bfcb8c28e761b4c67cdb97f31faba10b4b97fb0"

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
