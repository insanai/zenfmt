# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 4.1 | 3.3 | 3.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 63.5 | 64.7 | 49.7 |
| | | zenfmt-python-wheel | 94.5 | 92.7 | 31.4 |
| book.epub | 545.4560546875KiB | zenfmt | 47.7 | 46.5 | 22.9 |
| | | pandoc | 2008.9 | 1992.8 | 269.0 |
| | | anydoc | 96.4 | 95.9 | 54.0 |
| | | zenfmt-python-wheel | 219.3 | 217.4 | 54.4 |
| data.csv | 618.5078125KiB | zenfmt | 115.6 | 114.3 | 41.0 |
| | | pandoc | 1279.7 | 1264.3 | 290.3 |
| | | anydoc | 129.9 | 129.3 | 71.0 |
| | | zenfmt-python-wheel | 2179.8 | 2177.7 | 73.2 |
| deck.ppt | 2.4599609375MiB | zenfmt | 9.9 | 9.1 | 7.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 66.8 | 66.5 | 54.0 |
| | | zenfmt-python-wheel | 116.6 | 114.9 | 35.3 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 3.6 | 2.8 | 2.8 |
| | | pandoc | unsupported | | |
| | | anydoc | failed | | |
| | | zenfmt-python-wheel | 92.0 | 90.2 | 31.0 |
| letter.odt | 4.1591796875KiB | zenfmt | 3.8 | 3.0 | 2.9 |
| | | pandoc | 40.3 | 26.9 | 41.6 |
| | | anydoc | 61.8 | 61.5 | 47.0 |
| | | zenfmt-python-wheel | 91.8 | 89.9 | 30.9 |
| memo.doc | 32KiB | zenfmt | 3.6 | 2.8 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.1 | 61.8 | 47.2 |
| | | zenfmt-python-wheel | 93.0 | 91.2 | 31.0 |
| notes.rtf | 32.376953125KiB | zenfmt | 4.0 | 3.3 | 2.8 |
| | | pandoc | 65.1 | 47.0 | 104.5 |
| | | anydoc | 63.1 | 62.8 | 46.4 |
| | | zenfmt-python-wheel | 92.6 | 90.8 | 30.9 |
| page.html | 832.595703125KiB | zenfmt | 40.5 | 39.3 | 23.1 |
| | | pandoc | 1995.8 | 1984.4 | 426.5 |
| | | anydoc | unsupported | | |
| | | zenfmt-python-wheel | 213.0 | 211.5 | 54.0 |
| report.docx | 33.5693359375KiB | zenfmt | 4.8 | 3.9 | 3.2 |
| | | pandoc | 65.9 | 59.1 | 108.4 |
| | | anydoc | 63.1 | 62.7 | 48.0 |
| | | zenfmt-python-wheel | 96.7 | 95.0 | 31.1 |
| sheet.ods | 6.107421875KiB | zenfmt | 3.9 | 3.2 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.0 | 61.6 | 47.4 |
| | | zenfmt-python-wheel | 93.4 | 91.7 | 31.0 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 4.3 | 3.6 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 61.8 | 61.4 | 47.2 |
| | | zenfmt-python-wheel | 96.5 | 95.2 | 31.0 |
| slides.odp | 466.00390625KiB | zenfmt | 12.5 | 11.6 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 74.3 | 73.7 | 54.5 |
| | | zenfmt-python-wheel | 122.5 | 120.7 | 32.3 |
| slides.pptx | 633.080078125KiB | zenfmt | 11.7 | 10.9 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 71.6 | 71.2 | 49.2 |
| | | zenfmt-python-wheel | 127.7 | 125.9 | 32.3 |
| spec.pdf | 12.953125KiB | zenfmt | 3.6 | 2.8 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 61.4 | 62.3 | 48.9 |
| | | zenfmt-python-wheel | 92.6 | 90.8 | 31.0 |
| table.xls | 13KiB | zenfmt | 3.9 | 3.2 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.3 | 61.9 | 47.0 |
| | | zenfmt-python-wheel | 96.0 | 94.3 | 31.0 |

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
| zenfmt vs anydoc | 14 | 9.1x | 10.6x | 10.7x |
| zenfmt vs zenfmt-python-wheel | 16 | 16.4x | 18.9x | 7.0x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
