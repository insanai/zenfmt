#import "../../book/theme.typ": book

#show: doc => book(
  doc,
  title: "zenfmt 한국어 문서",
  authors: ("Zen Contributors",),
  keywords: ("문서 변환", "Zig", "Markdown"),
  running_head: "zenfmt 한국어 문서",
  font: "Noto Sans CJK KR",
  language: "ko",
)

#outline(indent: 1.2em)
#include "content.typ"
