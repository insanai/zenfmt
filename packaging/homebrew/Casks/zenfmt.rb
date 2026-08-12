cask "zenfmt" do
  arch arm: "aarch64", intel: "x86_64"

  version "0.3.3"
  sha256 arm:   "c12d137bb4a61f75d484c3d8747bf5f9681057c6b4093600d37834a6b0e10f99",
         intel: "2a923e9027717df05f4410b00f1ee237292b2fa9b67dbd65d9c1a75787c3776f"

  url "https://github.com/insanai/zenfmt/releases/download/v#{version}/zenfmt-#{version}-#{arch}-macos.tar.gz"
  name "zenfmt"
  desc "Self-contained document converter CLI and server"
  homepage "https://insanai.github.io/zenfmt/"

  binary "zenfmt-#{version}-#{arch}-macos/zenfmt"
end
