#import "../../book/web.typ": chapter_frame

#document(
  "index.html",
  title: "zenfmt 中文文档",
  author: ("Zen Contributors",),
  description: "从第一次转换到 CLI、Python、浏览器、server、限制和性能测试的实用指南。",
)[
  #show: doc => chapter_frame(doc, title: "zenfmt 中文文档")
  #set text(lang: "zh")
  #include "content.typ"
]
