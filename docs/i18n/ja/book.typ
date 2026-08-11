#import "../../book/theme.typ": book

#show: doc => book(
  doc,
  title: "zenfmt 日本語ドキュメント",
  authors: ("Zen Contributors",),
  keywords: ("ドキュメント変換", "Zig", "Markdown"),
  running_head: "zenfmt 日本語ドキュメント",
  font: "Noto Sans CJK JP",
  language: "ja",
)

#outline(indent: 1.2em)
#include "content.typ"
