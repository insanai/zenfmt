cask "zenfmt" do
  arch arm: "aarch64", intel: "x86_64"

  version "0.3.7"
  sha256 arm:   "a5c39aa59109b4e0462c7598a7363f607223d20dbadaaf7ca0e96fcf19a07dd9",
         intel: "9e566c77992a230fe4ffd2004ca419cd57082785980faa76581789b084733971"

  url "https://github.com/insanai/zenfmt/releases/download/v#{version}/zenfmt-#{version}-#{arch}-macos.tar.gz"
  name "zenfmt"
  desc "Self-contained document converter CLI and server"
  homepage "https://insanai.github.io/zenfmt/"

  binary "zenfmt-#{version}-#{arch}-macos/zenfmt"
end
