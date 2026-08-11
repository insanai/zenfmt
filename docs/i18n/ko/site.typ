#import "../../book/web.typ": chapter_frame

#document(
  "index.html",
  title: "zenfmt 한국어 문서",
  author: ("Zen Contributors",),
  description: "첫 변환부터 CLI, Python, 브라우저, server, 제한, 벤치마크까지 다루는 실용 안내서입니다.",
)[
  #show: doc => chapter_frame(doc, title: "zenfmt 한국어 문서")
  #set text(lang: "ko")
  #include "content.typ"
]
