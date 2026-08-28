cask "zenfmt" do
  arch arm: "aarch64", intel: "x86_64"

  version "0.3.6"
  sha256 arm:   "26006dffc14a96102498da11767e6fc24e303217f34e5857818174aaf0452b47",
         intel: "192e9aa8f363a76c4215842dda8bae233678b889784a89c8325774b79b87d48d"

  url "https://github.com/insanai/zenfmt/releases/download/v#{version}/zenfmt-#{version}-#{arch}-macos.tar.gz"
  name "zenfmt"
  desc "Self-contained document converter CLI and server"
  homepage "https://insanai.github.io/zenfmt/"

  binary "zenfmt-#{version}-#{arch}-macos/zenfmt"
end
