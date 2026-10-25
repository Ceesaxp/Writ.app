cask "writ" do
  version "0.6.0"
  sha256 "d83008b1d4c8b39a21f53928f693b9e654b0db7c4f5c12c7c5175cca78388fb5"

  url "https://github.com/Ceesaxp/Writ.app/releases/download/v#{version}/Writ-#{version}.dmg",
      verified: "github.com/Ceesaxp/Writ.app/"
  name "Writ"
  desc "Markdown editor for technical writing"
  homepage "https://ceesaxp.github.io/writ/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Writ.app"

  zap trash: [
    "~/Library/Caches/org.ceesaxp.Writ",
    "~/Library/HTTPStorages/org.ceesaxp.Writ",
    "~/Library/HTTPStorages/org.ceesaxp.Writ.binarycookies",
    "~/Library/Preferences/org.ceesaxp.Writ.plist",
    "~/Library/Saved Application State/org.ceesaxp.Writ.savedState",
    "~/Library/WebKit/org.ceesaxp.Writ",
  ]
end
