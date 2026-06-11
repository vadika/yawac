cask "yawac" do
  version "0.9.66"
  sha256 "f58e5728b3a0301eec3107b11b7f525030d121e6bc187cea461c73d61e900a18"

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
