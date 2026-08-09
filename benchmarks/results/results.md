# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 4.0 | 3.2 | 3.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 66.1 | 67.3 | 49.7 |
| | | zenfmt-python-wheel | 92.9 | 91.0 | 31.5 |
| book.epub | 545.4560546875KiB | zenfmt | 47.6 | 46.4 | 22.9 |
| | | pandoc | 2003.0 | 1989.5 | 269.0 |
| | | anydoc | 94.7 | 94.3 | 54.1 |
| | | zenfmt-python-wheel | 221.9 | 219.9 | 54.3 |
| data.csv | 618.5078125KiB | zenfmt | 120.2 | 118.4 | 41.0 |
| | | pandoc | 1281.3 | 1267.6 | 290.3 |
| | | anydoc | 131.3 | 130.8 | 70.9 |
| | | zenfmt-python-wheel | 2174.5 | 2172.4 | 73.4 |
| deck.ppt | 2.4599609375MiB | zenfmt | 9.9 | 8.9 | 7.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 64.9 | 64.6 | 54.0 |
| | | zenfmt-python-wheel | 116.7 | 114.9 | 35.5 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 3.5 | 2.8 | 2.8 |
| | | pandoc | unsupported | | |
| | | anydoc | failed | | |
| | | zenfmt-python-wheel | 93.6 | 91.9 | 30.8 |
| letter.odt | 4.1591796875KiB | zenfmt | 3.6 | 2.8 | 2.9 |
| | | pandoc | 40.3 | 26.8 | 41.6 |
| | | anydoc | 61.8 | 61.5 | 47.0 |
| | | zenfmt-python-wheel | 92.3 | 90.5 | 30.9 |
| memo.doc | 32KiB | zenfmt | 3.8 | 2.9 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.0 | 61.6 | 47.3 |
| | | zenfmt-python-wheel | 93.1 | 91.3 | 30.9 |
| notes.rtf | 32.376953125KiB | zenfmt | 4.3 | 3.4 | 2.8 |
| | | pandoc | 65.7 | 47.6 | 104.5 |
| | | anydoc | 63.9 | 63.6 | 46.5 |
| | | zenfmt-python-wheel | 92.8 | 90.9 | 30.9 |
| page.html | 832.595703125KiB | zenfmt | 40.5 | 39.3 | 23.1 |
| | | pandoc | 2001.3 | 1984.8 | 426.5 |
| | | anydoc | unsupported | | |
| | | zenfmt-python-wheel | 211.3 | 209.6 | 53.9 |
| report.docx | 33.5693359375KiB | zenfmt | 4.4 | 3.7 | 3.2 |
| | | pandoc | 65.4 | 58.8 | 108.4 |
| | | anydoc | 62.6 | 62.4 | 48.0 |
| | | zenfmt-python-wheel | 96.9 | 95.1 | 31.1 |
| sheet.ods | 6.107421875KiB | zenfmt | 3.9 | 3.1 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.7 | 62.1 | 47.5 |
| | | zenfmt-python-wheel | 93.6 | 91.8 | 31.0 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 4.3 | 3.5 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 61.5 | 61.3 | 47.3 |
| | | zenfmt-python-wheel | 97.4 | 95.5 | 31.1 |
| slides.odp | 466.00390625KiB | zenfmt | 12.5 | 11.6 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 75.1 | 74.8 | 54.4 |
| | | zenfmt-python-wheel | 123.1 | 121.3 | 32.3 |
| slides.pptx | 633.080078125KiB | zenfmt | 11.6 | 10.7 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 70.6 | 70.2 | 49.3 |
| | | zenfmt-python-wheel | 127.6 | 125.8 | 32.2 |
| spec.pdf | 12.953125KiB | zenfmt | 3.6 | 2.8 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.1 | 62.8 | 48.8 |
| | | zenfmt-python-wheel | 92.1 | 90.4 | 31.0 |
| table.xls | 13KiB | zenfmt | 3.9 | 3.1 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 63.0 | 62.9 | 47.0 |
| | | zenfmt-python-wheel | 95.8 | 94.0 | 31.0 |

## Support matrix

| tool | converted | of corpus |
|---|---:|---:|
| zenfmt | 16 | 16 |
| pandoc | 6 | 16 |
| anydoc | 14 | 16 |
| zenfmt-python-wheel | 16 | 16 |

## Head to head (geometric mean over commonly-converted files)

| pair | files | wall | cpu | peak RSS |
|---|---:|---:|---:|---:|
| zenfmt vs pandoc | 6 | 19.4x | 18.9x | 17.2x |
| zenfmt vs anydoc | 14 | 9.2x | 10.8x | 10.7x |
| zenfmt vs zenfmt-python-wheel | 16 | 16.6x | 19.1x | 7.0x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
