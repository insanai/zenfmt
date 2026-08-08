# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 6.0 | 4.9 | 3.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 41.5 | 42.3 | 49.6 |
| book.epub | 545.4560546875KiB | zenfmt | 29.7 | 29.0 | 22.9 |
| | | pandoc | 1292.1 | 1276.1 | 269.1 |
| | | anydoc | 60.2 | 59.8 | 54.2 |
| data.csv | 618.5078125KiB | zenfmt | 76.3 | 75.2 | 41.1 |
| | | pandoc | 819.5 | 804.8 | 290.2 |
| | | anydoc | 82.2 | 81.6 | 71.0 |
| deck.ppt | 2.4599609375MiB | zenfmt | 6.2 | 5.6 | 7.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 42.0 | 41.5 | 54.0 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 2.3 | 1.8 | 2.8 |
| | | pandoc | unsupported | | |
| | | anydoc | failed | | |
| letter.odt | 4.1591796875KiB | zenfmt | 2.4 | 1.8 | 2.9 |
| | | pandoc | 33.3 | 19.0 | 41.5 |
| | | anydoc | 39.0 | 38.6 | 46.9 |
| memo.doc | 32KiB | zenfmt | 2.4 | 1.8 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 39.4 | 39.1 | 47.1 |
| notes.rtf | 32.376953125KiB | zenfmt | 2.7 | 2.2 | 2.9 |
| | | pandoc | 50.0 | 33.1 | 104.5 |
| | | anydoc | 39.8 | 39.4 | 46.3 |
| page.html | 832.595703125KiB | zenfmt | 25.5 | 24.8 | 23.2 |
| | | pandoc | 1274.9 | 1259.0 | 426.5 |
| | | anydoc | unsupported | | |
| report.docx | 33.5693359375KiB | zenfmt | 3.0 | 2.5 | 3.2 |
| | | pandoc | 49.3 | 39.1 | 108.4 |
| | | anydoc | 39.8 | 39.5 | 47.9 |
| sheet.ods | 6.107421875KiB | zenfmt | 2.4 | 1.9 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 39.6 | 39.2 | 47.3 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 2.7 | 2.2 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 38.7 | 38.4 | 47.2 |
| slides.odp | 466.00390625KiB | zenfmt | 7.6 | 7.1 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 46.8 | 46.3 | 54.4 |
| slides.pptx | 633.080078125KiB | zenfmt | 7.1 | 6.6 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 44.5 | 44.1 | 49.3 |
| spec.pdf | 12.953125KiB | zenfmt | 2.3 | 1.8 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 40.1 | 40.8 | 48.8 |
| table.xls | 13KiB | zenfmt | 2.4 | 1.9 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 39.4 | 39.0 | 46.9 |

## Support matrix

| tool | converted | of corpus |
|---|---:|---:|
| zenfmt | 16 | 16 |
| pandoc | 6 | 16 |
| anydoc | 14 | 16 |

## Head to head (geometric mean over commonly-converted files)

| pair | files | wall | cpu | peak RSS |
|---|---:|---:|---:|---:|
| zenfmt vs pandoc | 6 | 21.3x | 19.6x | 17.2x |
| zenfmt vs anydoc | 14 | 8.6x | 10.1x | 10.7x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
