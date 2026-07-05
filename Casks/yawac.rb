cask "yawac" do
  version "0.10.45"
  sha256 "7600d15529de3253a1d30468498a186c42f41388196ee4ae57ad28f60c88745e"

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
