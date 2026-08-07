# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 7.1 | 5.6 | 3.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 41.1 | 42.0 | 49.5 |
| book.epub | 545.4560546875KiB | zenfmt | 33.0 | 31.9 | 22.8 |
| | | pandoc | 1385.4 | 1371.0 | 269.1 |
| | | anydoc | 70.5 | 69.6 | 54.4 |
| data.csv | 618.5078125KiB | zenfmt | 232.0 | 230.6 | 36.8 |
| | | pandoc | 891.8 | 881.2 | 290.2 |
| | | anydoc | 118.3 | 87.7 | 71.1 |
| deck.ppt | 2.4599609375MiB | zenfmt | 10.9 | 8.4 | 7.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.0 | 53.3 | 54.2 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 2.5 | 1.9 | 2.8 |
| | | pandoc | unsupported | | |
| | | anydoc | failed | | |
| letter.odt | 4.1591796875KiB | zenfmt | 6.1 | 4.5 | 2.9 |
| | | pandoc | 38.1 | 24.1 | 41.6 |
| | | anydoc | 41.0 | 40.6 | 46.9 |
| memo.doc | 32KiB | zenfmt | 2.4 | 1.9 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 40.6 | 40.2 | 47.1 |
| notes.rtf | 32.376953125KiB | zenfmt | 2.6 | 2.1 | 2.8 |
| | | pandoc | 43.5 | 31.7 | 104.5 |
| | | anydoc | 40.7 | 40.2 | 46.3 |
| page.html | 832.595703125KiB | zenfmt | 28.9 | 27.9 | 23.1 |
| | | pandoc | 1264.1 | 1251.1 | 426.5 |
| | | anydoc | unsupported | | |
| report.docx | 33.5693359375KiB | zenfmt | 2.9 | 2.4 | 3.1 |
| | | pandoc | 43.4 | 38.7 | 108.3 |
| | | anydoc | 40.9 | 40.4 | 47.9 |
| sheet.ods | 6.107421875KiB | zenfmt | 2.5 | 2.0 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 41.1 | 40.8 | 47.3 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 2.9 | 2.4 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 40.3 | 39.9 | 47.2 |
| slides.odp | 466.00390625KiB | zenfmt | 8.6 | 7.9 | 4.1 |
| | | pandoc | unsupported | | |
| | | anydoc | 49.8 | 49.3 | 54.4 |
| slides.pptx | 633.080078125KiB | zenfmt | 8.1 | 7.4 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 46.1 | 45.7 | 49.3 |
| spec.pdf | 12.953125KiB | zenfmt | 2.2 | 1.7 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 41.1 | 41.9 | 48.8 |
| table.xls | 13KiB | zenfmt | 2.7 | 2.1 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 40.6 | 39.8 | 46.9 |

## Support matrix

| tool | converted | of corpus |
|---|---:|---:|
| zenfmt | 16 | 16 |
| pandoc | 6 | 16 |
| anydoc | 14 | 16 |

## Head to head (geometric mean over commonly-converted files)

| pair | files | wall | cpu | peak RSS |
|---|---:|---:|---:|---:|
| zenfmt vs pandoc | 6 | 14.8x | 14.5x | 17.6x |
| zenfmt vs anydoc | 14 | 7.4x | 8.6x | 10.8x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
