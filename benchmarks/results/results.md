# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 6.8 | 5.8 | 3.6 |
| | | docling | unsupported | | |
| | | anydoc | 63.3 | 64.7 | 49.7 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 92.8 | 91.0 | 31.4 |
| book.epub | 545.4560546875KiB | zenfmt | 127.9 | 126.4 | 23.1 |
| | | docling | unsupported | | |
| | | anydoc | 95.2 | 94.7 | 54.1 |
| | | pandoc | 2001.5 | 1985.9 | 269.0 |
| | | zenfmt-python-wheel | 219.5 | 217.7 | 54.1 |
| data.csv | 618.5078125KiB | zenfmt | 2084.0 | 2082.0 | 41.2 |
| | | docling | 4906.4 | 4892.7 | 565.2 |
| | | anydoc | 128.9 | 128.3 | 68.0 |
| | | pandoc | 1279.0 | 1264.4 | 290.3 |
| | | zenfmt-python-wheel | 2175.8 | 2173.7 | 73.3 |
| deck.ppt | 2.4599609375MiB | zenfmt | 28.9 | 27.7 | 7.5 |
| | | docling | unsupported | | |
| | | anydoc | 65.4 | 65.0 | 54.0 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 117.3 | 115.5 | 35.3 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 4.6 | 3.8 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | failed | | |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 92.8 | 90.9 | 30.8 |
| letter.odt | 4.1591796875KiB | zenfmt | 4.5 | 3.7 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 62.5 | 62.3 | 47.0 |
| | | pandoc | 40.8 | 27.3 | 41.6 |
| | | zenfmt-python-wheel | 92.4 | 90.7 | 31.0 |
| memo.doc | 32KiB | zenfmt | 5.5 | 4.6 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | 61.8 | 61.5 | 47.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 93.0 | 91.2 | 30.9 |
| notes.rtf | 32.376953125KiB | zenfmt | 5.1 | 4.2 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 62.8 | 62.6 | 46.3 |
| | | pandoc | 65.7 | 47.8 | 104.5 |
| | | zenfmt-python-wheel | 93.4 | 91.4 | 30.9 |
| page.html | 832.595703125KiB | zenfmt | 122.1 | 120.6 | 23.4 |
| | | docling | 4805.4 | 4795.6 | 391.0 |
| | | anydoc | unsupported | | |
| | | pandoc | 1998.2 | 1983.5 | 426.5 |
| | | zenfmt-python-wheel | 212.6 | 210.7 | 54.0 |
| report.docx | 33.5693359375KiB | zenfmt | 9.0 | 8.2 | 3.4 |
| | | docling | 3788.9 | 3775.6 | 373.2 |
| | | anydoc | 63.3 | 63.1 | 48.0 |
| | | pandoc | 75.2 | 59.7 | 108.4 |
| | | zenfmt-python-wheel | 97.5 | 95.6 | 31.2 |
| sheet.ods | 6.107421875KiB | zenfmt | 6.0 | 5.2 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 63.1 | 62.9 | 47.4 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 94.3 | 92.4 | 31.0 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 9.9 | 9.0 | 3.2 |
| | | docling | 3715.6 | 3704.1 | 370.0 |
| | | anydoc | 63.3 | 62.9 | 47.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 97.6 | 95.8 | 31.0 |
| slides.odp | 466.00390625KiB | zenfmt | 35.3 | 34.3 | 4.4 |
| | | docling | unsupported | | |
| | | anydoc | 75.2 | 74.8 | 54.4 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 124.0 | 122.2 | 32.3 |
| slides.pptx | 633.080078125KiB | zenfmt | 40.2 | 39.1 | 4.4 |
| | | docling | 4224.3 | 4216.1 | 379.6 |
| | | anydoc | 72.2 | 72.0 | 49.2 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 128.1 | 126.2 | 32.3 |
| spec.pdf | 12.953125KiB | zenfmt | 4.4 | 3.6 | 3.2 |
| | | docling | unsupported | | |
| | | anydoc | 62.6 | 63.2 | 48.8 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 92.6 | 90.8 | 31.1 |
| table.xls | 13KiB | zenfmt | 8.2 | 7.4 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 61.5 | 61.1 | 46.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 96.4 | 94.6 | 31.0 |

## Support matrix

| tool | converted | of corpus |
|---|---:|---:|
| zenfmt | 16 | 16 |
| docling | 5 | 16 |
| anydoc | 14 | 16 |
| pandoc | 6 | 16 |
| zenfmt-python-wheel | 16 | 16 |

## Head to head (geometric mean over commonly-converted files)

| pair | files | wall | cpu | peak RSS |
|---|---:|---:|---:|---:|
| zenfmt vs docling | 5 | 68.5x | 71.6x | 47.5x |
| zenfmt vs anydoc | 14 | 4.1x | 4.5x | 10.1x |
| zenfmt vs pandoc | 6 | 7.3x | 6.7x | 16.6x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
