# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 4.3 | 3.4 | 3.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 63.5 | 64.9 | 49.6 |
| | | zenfmt-python-wheel | 92.8 | 90.9 | 31.5 |
| book.epub | 545.4560546875KiB | zenfmt | 47.4 | 46.5 | 22.9 |
| | | pandoc | 1992.1 | 1985.1 | 269.0 |
| | | anydoc | 96.0 | 95.5 | 54.2 |
| | | zenfmt-python-wheel | 218.1 | 216.2 | 54.3 |
| data.csv | 618.5078125KiB | zenfmt | 119.3 | 117.9 | 41.0 |
| | | pandoc | 1273.9 | 1260.3 | 290.2 |
| | | anydoc | 129.7 | 129.1 | 71.0 |
| | | zenfmt-python-wheel | 2176.8 | 2174.8 | 73.3 |
| deck.ppt | 2.4599609375MiB | zenfmt | 10.2 | 9.3 | 7.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 65.2 | 64.9 | 53.9 |
| | | zenfmt-python-wheel | 116.1 | 114.3 | 35.5 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 3.6 | 2.8 | 2.8 |
| | | pandoc | unsupported | | |
| | | anydoc | failed | | |
| | | zenfmt-python-wheel | 92.6 | 90.8 | 30.9 |
| letter.odt | 4.1591796875KiB | zenfmt | 3.8 | 2.9 | 2.9 |
| | | pandoc | 40.6 | 26.7 | 41.6 |
| | | anydoc | 62.9 | 62.6 | 47.0 |
| | | zenfmt-python-wheel | 93.9 | 92.0 | 31.0 |
| memo.doc | 32KiB | zenfmt | 3.9 | 3.1 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.3 | 62.0 | 47.2 |
| | | zenfmt-python-wheel | 93.0 | 91.3 | 31.0 |
| notes.rtf | 32.376953125KiB | zenfmt | 4.0 | 3.2 | 2.8 |
| | | pandoc | 65.4 | 47.2 | 104.5 |
| | | anydoc | 62.5 | 62.3 | 46.4 |
| | | zenfmt-python-wheel | 92.1 | 90.3 | 30.9 |
| page.html | 832.595703125KiB | zenfmt | 40.5 | 39.2 | 23.1 |
| | | pandoc | 1992.5 | 1979.3 | 426.5 |
| | | anydoc | unsupported | | |
| | | zenfmt-python-wheel | 211.7 | 209.9 | 54.0 |
| report.docx | 33.5693359375KiB | zenfmt | 4.5 | 3.7 | 3.2 |
| | | pandoc | 65.7 | 59.0 | 108.4 |
| | | anydoc | 62.7 | 62.4 | 48.0 |
| | | zenfmt-python-wheel | 97.3 | 95.5 | 31.2 |
| sheet.ods | 6.107421875KiB | zenfmt | 3.9 | 3.1 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.0 | 61.7 | 47.5 |
| | | zenfmt-python-wheel | 93.5 | 91.7 | 31.0 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 4.4 | 3.6 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 62.1 | 61.8 | 47.3 |
| | | zenfmt-python-wheel | 97.2 | 95.4 | 31.1 |
| slides.odp | 466.00390625KiB | zenfmt | 12.3 | 11.5 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 74.5 | 74.1 | 54.4 |
| | | zenfmt-python-wheel | 122.2 | 120.8 | 32.2 |
| slides.pptx | 633.080078125KiB | zenfmt | 11.6 | 10.7 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 71.1 | 70.8 | 49.3 |
| | | zenfmt-python-wheel | 128.0 | 126.2 | 32.4 |
| spec.pdf | 12.953125KiB | zenfmt | 3.6 | 2.8 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 63.0 | 63.8 | 48.8 |
| | | zenfmt-python-wheel | 92.3 | 90.4 | 31.0 |
| table.xls | 13KiB | zenfmt | 3.9 | 3.1 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 63.5 | 63.3 | 46.9 |
| | | zenfmt-python-wheel | 95.9 | 94.1 | 31.0 |

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
| zenfmt vs pandoc | 6 | 19.5x | 18.9x | 17.2x |
| zenfmt vs anydoc | 14 | 9.1x | 10.7x | 10.7x |
| zenfmt vs zenfmt-python-wheel | 16 | 16.4x | 18.9x | 7.0x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
