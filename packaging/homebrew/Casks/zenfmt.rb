cask "zenfmt" do
  arch arm: "aarch64", intel: "x86_64"

  version "0.3.5"
  sha256 arm:   "3dcad02dfdf1cf985cb62a5ba1084a0a546bc71569d8d58ee5fab642949bfd2a",
         intel: "49438c9ad16e3027a11b5af5e3f1b3722e8ed395daf0d731328bd64183e9d84e"

  url "https://github.com/insanai/zenfmt/releases/download/v#{version}/zenfmt-#{version}-#{arch}-macos.tar.gz"
  name "zenfmt"
  desc "Self-contained document converter CLI and server"
  homepage "https://insanai.github.io/zenfmt/"

  binary "zenfmt-#{version}-#{arch}-macos/zenfmt"
end
