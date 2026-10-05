cask "writ" do
  version "0.5.6"
  sha256 "ca72892926f751a60381e2dfb597bdf0ab643d2de62d733c67afa891df472c53"

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
