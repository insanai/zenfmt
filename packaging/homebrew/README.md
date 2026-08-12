# Homebrew tap for zenfmt

This directory is a complete Homebrew tap layout. It can be moved to a
dedicated `homebrew-zenfmt` repository without changing the cask path.

Until that repository is available, install the cask directly from this
repository:

```sh
brew install --cask \
  https://raw.githubusercontent.com/insanai/zenfmt/main/packaging/homebrew/Casks/zenfmt.rb
```

The cask downloads the matching Apple Silicon or Intel CLI archive directly
from the tagged GitHub release. That archive contains one self-contained
`zenfmt` executable with both the CLI and server. Homebrew does not build the
project and does not install a Java, Python, Node, OCR, VLM, or model runtime.

After this directory becomes its own repository, the usual commands will be:

```sh
brew tap insanai/zenfmt
brew install --cask zenfmt
```
