cask "yawac" do
  version "0.10.5"
  sha256 "edc6526835ff0dbc558829e6b9ca8ce0a249c2a244d1c1e191f1d251c068ce7c"

  url "https://github.com/vadika/yawac/releases/download/v#{version}/yawac-#{version}.zip"
  name "yawac"
  desc "Yet Another Client for WhatsApp — native macOS SwiftUI"
  homepage "https://github.com/vadika/yawac"

  depends_on macos: ">= :sonoma"

  app "yawac.app"

  zap trash: [
    "~/Library/Application Support/yawac",
    "~/Library/Preferences/dev.vadikas.yawac.plist",
    "~/Library/Caches/dev.vadikas.yawac",
  ]
end
