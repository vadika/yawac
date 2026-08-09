cask "yawac" do
  version "0.10.54"
  sha256 "1c61a892c555e4315d782e70e84dc86121b1d07c3fbb187a74844cdee95da725"

  url "https://github.com/vadika/yawac/releases/download/v#{version}/yawac-#{version}.zip"
  name "yawac"
  desc "Yet Another Client for WhatsApp — native macOS SwiftUI"
  homepage "https://github.com/vadika/yawac"

  depends_on macos: :sonoma

  app "yawac.app"

  zap trash: [
    "~/Library/Application Support/yawac",
    "~/Library/Preferences/dev.vadikas.yawac.plist",
    "~/Library/Caches/dev.vadikas.yawac",
  ]
end
