#import "../../book/web.typ": chapter_frame

#document(
  "index.html",
  title: "zenfmt 日本語ドキュメント",
  author: ("Zen Contributors",),
  description: "最初の変換から CLI、Python、ブラウザ、server、上限、ベンチマークまでを扱う実用ガイド。",
)[
  #show: doc => chapter_frame(doc, title: "zenfmt 日本語ドキュメント")
  #set text(lang: "ja")
  #include "content.typ"
]
