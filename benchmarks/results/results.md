# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 4.5 | 3.4 | 3.1 |
| | | pandoc | unsupported | | |
| | | anydoc | 66.7 | 67.7 | 49.6 |
| book.epub | 545.4560546875KiB | zenfmt | 47.8 | 46.3 | 23.5 |
| | | pandoc | 2004.2 | 1993.2 | 269.0 |
| | | anydoc | 99.2 | 98.7 | 54.2 |
| data.csv | 618.5078125KiB | zenfmt | 254.1 | 252.2 | 36.7 |
| | | pandoc | 1267.2 | 1254.4 | 290.3 |
| | | anydoc | 132.0 | 131.4 | 71.0 |
| deck.ppt | 2.4599609375MiB | zenfmt | 10.5 | 9.5 | 7.1 |
| | | pandoc | unsupported | | |
| | | anydoc | 69.3 | 68.9 | 54.0 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 3.5 | 2.7 | 2.6 |
| | | pandoc | unsupported | | |
| | | anydoc | failed | | |
| letter.odt | 4.1591796875KiB | zenfmt | 3.6 | 2.8 | 2.7 |
| | | pandoc | 41.2 | 27.8 | 41.6 |
| | | anydoc | 64.2 | 63.9 | 46.9 |
| memo.doc | 32KiB | zenfmt | 3.8 | 2.9 | 2.7 |
| | | pandoc | unsupported | | |
| | | anydoc | 63.0 | 62.7 | 47.2 |
| notes.rtf | 32.376953125KiB | zenfmt | 4.1 | 3.3 | 2.7 |
| | | pandoc | 66.3 | 48.0 | 104.5 |
| | | anydoc | 63.3 | 62.9 | 46.3 |
| page.html | 832.595703125KiB | zenfmt | 40.2 | 38.9 | 22.9 |
| | | pandoc | 1981.1 | 1968.6 | 426.5 |
| | | anydoc | unsupported | | |
| report.docx | 33.5693359375KiB | zenfmt | 4.7 | 3.8 | 2.9 |
| | | pandoc | 66.0 | 59.6 | 108.4 |
| | | anydoc | 64.5 | 64.2 | 47.8 |
| sheet.ods | 6.107421875KiB | zenfmt | 3.9 | 3.1 | 2.7 |
| | | pandoc | unsupported | | |
| | | anydoc | 64.1 | 63.8 | 47.3 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 4.5 | 3.6 | 2.7 |
| | | pandoc | unsupported | | |
| | | anydoc | 63.2 | 62.9 | 47.2 |
| slides.odp | 466.00390625KiB | zenfmt | 13.0 | 12.1 | 4.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 76.2 | 75.7 | 54.5 |
| slides.pptx | 633.080078125KiB | zenfmt | 11.7 | 10.7 | 3.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 74.6 | 74.3 | 49.3 |
| spec.pdf | 12.953125KiB | zenfmt | 3.6 | 2.7 | 2.7 |
| | | pandoc | unsupported | | |
| | | anydoc | 63.3 | 64.2 | 48.7 |
| table.xls | 13KiB | zenfmt | 4.0 | 3.1 | 2.7 |
| | | pandoc | unsupported | | |
| | | anydoc | 63.0 | 62.7 | 46.9 |

## Support matrix

| tool | converted | of corpus |
|---|---:|---:|
| zenfmt | 16 | 16 |
| pandoc | 6 | 16 |
| anydoc | 14 | 16 |

## Head to head (geometric mean over commonly-converted files)

| pair | files | wall | cpu | peak RSS |
|---|---:|---:|---:|---:|
| zenfmt vs pandoc | 6 | 17.2x | 17.0x | 18.2x |
| zenfmt vs anydoc | 14 | 8.7x | 10.3x | 11.4x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
