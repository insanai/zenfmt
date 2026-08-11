#import "../../book/theme.typ": book

#show: doc => book(
  doc,
  title: "zenfmt 中文文档",
  authors: ("Zen Contributors",),
  keywords: ("文档转换", "Zig", "Markdown"),
  running_head: "zenfmt 中文文档",
  font: "Noto Sans CJK SC",
  language: "zh",
)

#outline(indent: 1.2em)
#include "content.typ"
