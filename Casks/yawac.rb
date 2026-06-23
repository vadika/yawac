cask "yawac" do
  version "0.10.33"
  sha256 "47b786b44b30850f976225df3f1bec0f743653f46f9c01b1858bbdd93d962bd5"

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
