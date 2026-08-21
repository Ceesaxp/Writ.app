cask "writ" do
  version "0.5.5"
  sha256 "f13dcd3db3397586558f3e857782793bae83d4d6bdf9b49d0542184628754852"

  url "https://github.com/Ceesaxp/Writ.app/releases/download/v#{version}/Writ-#{version}.dmg",
      verified: "github.com/Ceesaxp/Writ.app/"
  name "Writ"
  desc "Markdown editor for technical writing"
  homepage "https://github.com/Ceesaxp/Writ.app"

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
