cask "yawac" do
  version "0.9.10"
  sha256 "3c8f26f8788152781742b8bddcf7b5d6218578f73f37d40f7db6bb03f86bcb9a"

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
