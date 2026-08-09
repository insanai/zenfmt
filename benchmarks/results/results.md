# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 4.1 | 3.3 | 3.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 64.1 | 65.3 | 49.7 |
| | | zenfmt-python-wheel | 92.6 | 90.8 | 31.5 |
| book.epub | 545.4560546875KiB | zenfmt | 47.8 | 46.5 | 22.9 |
| | | pandoc | 2002.3 | 1986.1 | 269.1 |
| | | anydoc | 94.7 | 94.3 | 54.1 |
| | | zenfmt-python-wheel | 218.5 | 216.6 | 54.3 |
| data.csv | 618.5078125KiB | zenfmt | 125.0 | 123.4 | 41.0 |
| | | pandoc | 1271.5 | 1261.5 | 290.3 |
| | | anydoc | 130.4 | 129.8 | 71.0 |
| | | zenfmt-python-wheel | 2179.3 | 2177.3 | 73.3 |
| deck.ppt | 2.4599609375MiB | zenfmt | 9.9 | 8.9 | 7.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 64.8 | 64.5 | 54.0 |
| | | zenfmt-python-wheel | 116.1 | 114.2 | 35.3 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 3.6 | 2.8 | 2.8 |
| | | pandoc | unsupported | | |
| | | anydoc | failed | | |
| | | zenfmt-python-wheel | 91.4 | 89.7 | 30.7 |
| letter.odt | 4.1591796875KiB | zenfmt | 3.6 | 2.8 | 2.9 |
| | | pandoc | 40.6 | 26.7 | 41.6 |
| | | anydoc | 60.9 | 60.6 | 47.0 |
| | | zenfmt-python-wheel | 92.0 | 90.2 | 31.0 |
| memo.doc | 32KiB | zenfmt | 3.6 | 2.9 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 61.5 | 61.2 | 47.3 |
| | | zenfmt-python-wheel | 92.9 | 91.1 | 31.0 |
| notes.rtf | 32.376953125KiB | zenfmt | 4.1 | 3.3 | 2.8 |
| | | pandoc | 65.1 | 47.2 | 104.5 |
| | | anydoc | 62.2 | 61.8 | 46.3 |
| | | zenfmt-python-wheel | 92.1 | 90.3 | 30.9 |
| page.html | 832.595703125KiB | zenfmt | 40.4 | 39.2 | 23.1 |
| | | pandoc | 1994.4 | 1983.4 | 426.5 |
| | | anydoc | unsupported | | |
| | | zenfmt-python-wheel | 212.1 | 210.0 | 54.0 |
| report.docx | 33.5693359375KiB | zenfmt | 4.6 | 3.7 | 3.2 |
| | | pandoc | 65.4 | 58.8 | 108.4 |
| | | anydoc | 62.8 | 62.6 | 48.0 |
| | | zenfmt-python-wheel | 97.1 | 95.3 | 31.2 |
| sheet.ods | 6.107421875KiB | zenfmt | 4.0 | 3.2 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.5 | 62.3 | 47.5 |
| | | zenfmt-python-wheel | 93.5 | 91.7 | 30.9 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 4.3 | 3.5 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.1 | 61.8 | 47.3 |
| | | zenfmt-python-wheel | 97.4 | 95.6 | 31.0 |
| slides.odp | 466.00390625KiB | zenfmt | 12.4 | 11.5 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 74.5 | 74.0 | 54.5 |
| | | zenfmt-python-wheel | 122.7 | 121.0 | 32.3 |
| slides.pptx | 633.080078125KiB | zenfmt | 11.6 | 10.8 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 72.3 | 72.0 | 49.3 |
| | | zenfmt-python-wheel | 128.0 | 126.2 | 32.2 |
| spec.pdf | 12.953125KiB | zenfmt | 3.6 | 2.8 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 64.6 | 65.6 | 48.8 |
| | | zenfmt-python-wheel | 92.0 | 90.1 | 31.1 |
| table.xls | 13KiB | zenfmt | 4.1 | 3.3 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.7 | 62.4 | 46.9 |
| | | zenfmt-python-wheel | 95.6 | 93.9 | 31.0 |

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
| zenfmt vs pandoc | 6 | 19.3x | 18.8x | 17.2x |
| zenfmt vs anydoc | 14 | 9.1x | 10.7x | 10.7x |
| zenfmt vs zenfmt-python-wheel | 16 | 16.4x | 18.9x | 7.0x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
