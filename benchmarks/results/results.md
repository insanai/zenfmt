# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 5.3 | 4.4 | 3.6 |
| | | docling | unsupported | | |
| | | anydoc | 67.7 | 68.2 | 49.7 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 94.4 | 92.5 | 31.5 |
| book.epub | 545.4560546875KiB | zenfmt | 64.0 | 62.5 | 23.1 |
| | | docling | unsupported | | |
| | | anydoc | 97.9 | 97.5 | 54.1 |
| | | pandoc | 2001.1 | 1991.0 | 269.0 |
| | | zenfmt-python-wheel | 156.1 | 154.3 | 54.1 |
| data.csv | 618.5078125KiB | zenfmt | 86.9 | 84.9 | 41.2 |
| | | docling | 4943.5 | 4928.8 | 565.2 |
| | | anydoc | 130.8 | 130.2 | 67.9 |
| | | pandoc | 1280.3 | 1270.0 | 290.3 |
| | | zenfmt-python-wheel | 177.7 | 175.9 | 73.3 |
| deck.ppt | 2.4599609375MiB | zenfmt | 12.5 | 11.4 | 7.5 |
| | | docling | unsupported | | |
| | | anydoc | 66.1 | 66.0 | 53.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 101.7 | 99.8 | 35.3 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 4.6 | 3.7 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | failed | | |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 92.0 | 90.3 | 31.0 |
| letter.odt | 4.1591796875KiB | zenfmt | 4.7 | 3.8 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 63.1 | 62.8 | 47.1 |
| | | pandoc | 40.4 | 27.3 | 41.6 |
| | | zenfmt-python-wheel | 92.7 | 90.9 | 31.0 |
| memo.doc | 32KiB | zenfmt | 4.4 | 3.5 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | 62.2 | 61.9 | 47.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 92.0 | 90.3 | 30.8 |
| notes.rtf | 32.376953125KiB | zenfmt | 4.9 | 4.0 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 65.6 | 65.3 | 46.4 |
| | | pandoc | 65.9 | 47.9 | 104.5 |
| | | zenfmt-python-wheel | 93.0 | 91.2 | 31.0 |
| page.html | 832.595703125KiB | zenfmt | 57.9 | 56.8 | 23.3 |
| | | docling | 4832.2 | 4818.2 | 391.9 |
| | | anydoc | unsupported | | |
| | | pandoc | 1991.8 | 1975.9 | 426.5 |
| | | zenfmt-python-wheel | 147.2 | 145.4 | 53.9 |
| report.docx | 33.5693359375KiB | zenfmt | 7.2 | 6.3 | 3.4 |
| | | docling | 3807.7 | 3797.5 | 373.4 |
| | | anydoc | 66.9 | 66.5 | 48.0 |
| | | pandoc | 66.1 | 59.4 | 108.4 |
| | | zenfmt-python-wheel | 95.6 | 93.7 | 31.2 |
| sheet.ods | 6.107421875KiB | zenfmt | 5.1 | 4.1 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 65.8 | 65.6 | 47.5 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 94.9 | 93.0 | 31.0 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 6.3 | 5.3 | 3.2 |
| | | docling | 3725.9 | 3717.3 | 370.0 |
| | | anydoc | 64.5 | 64.1 | 47.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 94.2 | 92.4 | 31.0 |
| slides.odp | 466.00390625KiB | zenfmt | 25.5 | 24.4 | 4.4 |
| | | docling | unsupported | | |
| | | anydoc | 76.5 | 76.2 | 54.4 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 112.7 | 110.9 | 32.3 |
| slides.pptx | 633.080078125KiB | zenfmt | 30.8 | 29.7 | 4.4 |
| | | docling | 4254.6 | 4242.2 | 379.2 |
| | | anydoc | 75.0 | 74.7 | 49.2 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 119.1 | 117.2 | 32.3 |
| spec.pdf | 12.953125KiB | zenfmt | 4.5 | 3.6 | 3.2 |
| | | docling | unsupported | | |
| | | anydoc | 65.7 | 66.6 | 48.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 92.3 | 90.4 | 31.1 |
| table.xls | 13KiB | zenfmt | 4.8 | 3.9 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 62.9 | 62.6 | 47.0 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 93.0 | 91.2 | 31.1 |

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
| zenfmt vs docling | 5 | 182.2x | 196.3x | 47.5x |
| zenfmt vs anydoc | 14 | 7.0x | 8.0x | 10.1x |
| zenfmt vs pandoc | 6 | 15.9x | 15.3x | 16.6x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
