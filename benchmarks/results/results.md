# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 3.4 | 2.8 | 3.6 |
| | | docling | unsupported | | |
| | | anydoc | 41.5 | 42.2 | 49.7 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 59.2 | 57.8 | 31.3 |
| book.epub | 545.4560546875KiB | zenfmt | 39.9 | 38.9 | 23.1 |
| | | docling | unsupported | | |
| | | anydoc | 60.8 | 60.2 | 54.3 |
| | | pandoc | 1303.7 | 1293.6 | 269.1 |
| | | zenfmt-python-wheel | 97.3 | 95.7 | 54.3 |
| data.csv | 618.5078125KiB | zenfmt | 53.9 | 52.7 | 41.2 |
| | | docling | 3207.2 | 3198.7 | 565.3 |
| | | anydoc | 83.1 | 82.5 | 68.0 |
| | | pandoc | 829.4 | 814.9 | 290.3 |
| | | zenfmt-python-wheel | 112.4 | 110.8 | 73.4 |
| deck.ppt | 2.4599609375MiB | zenfmt | 8.0 | 7.3 | 7.6 |
| | | docling | unsupported | | |
| | | anydoc | 42.1 | 41.6 | 53.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 63.4 | 62.0 | 35.5 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 2.8 | 2.3 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | failed | | |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.1 | 56.7 | 30.9 |
| letter.odt | 4.1591796875KiB | zenfmt | 2.8 | 2.3 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 40.0 | 39.5 | 47.0 |
| | | pandoc | 33.2 | 19.4 | 41.6 |
| | | zenfmt-python-wheel | 58.8 | 57.3 | 31.1 |
| memo.doc | 32KiB | zenfmt | 2.9 | 2.3 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | 40.1 | 39.7 | 47.2 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.6 | 57.2 | 31.0 |
| notes.rtf | 32.376953125KiB | zenfmt | 3.0 | 2.5 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 39.4 | 39.0 | 46.5 |
| | | pandoc | 44.9 | 32.8 | 104.5 |
| | | zenfmt-python-wheel | 58.7 | 57.2 | 30.9 |
| page.html | 832.595703125KiB | zenfmt | 36.3 | 35.3 | 23.4 |
| | | docling | 3089.9 | 3079.5 | 392.7 |
| | | anydoc | unsupported | | |
| | | pandoc | 1289.3 | 1273.4 | 426.5 |
| | | zenfmt-python-wheel | 93.3 | 91.8 | 53.9 |
| report.docx | 33.5693359375KiB | zenfmt | 4.5 | 3.8 | 3.4 |
| | | docling | 2472.3 | 2462.1 | 373.4 |
| | | anydoc | 41.3 | 40.8 | 47.9 |
| | | pandoc | 53.8 | 40.3 | 108.4 |
| | | zenfmt-python-wheel | 60.5 | 59.0 | 31.2 |
| sheet.ods | 6.107421875KiB | zenfmt | 3.1 | 2.6 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 40.2 | 39.8 | 47.5 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.7 | 57.2 | 31.0 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 3.8 | 3.2 | 3.2 |
| | | docling | 2425.1 | 2415.1 | 370.0 |
| | | anydoc | 40.5 | 40.1 | 47.2 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 60.0 | 58.7 | 31.0 |
| slides.odp | 466.00390625KiB | zenfmt | 15.8 | 15.1 | 4.4 |
| | | docling | unsupported | | |
| | | anydoc | 46.6 | 46.2 | 54.4 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 71.6 | 70.2 | 32.3 |
| slides.pptx | 633.080078125KiB | zenfmt | 18.9 | 18.3 | 4.4 |
| | | docling | 2737.5 | 2731.4 | 379.1 |
| | | anydoc | 45.0 | 44.6 | 49.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 74.6 | 73.3 | 32.3 |
| spec.pdf | 12.953125KiB | zenfmt | 2.7 | 2.2 | 3.2 |
| | | docling | unsupported | | |
| | | anydoc | 39.1 | 39.7 | 48.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.3 | 56.9 | 31.1 |
| table.xls | 13KiB | zenfmt | 2.8 | 2.3 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 39.3 | 39.1 | 46.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.3 | 57.0 | 31.0 |

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
| zenfmt vs docling | 5 | 190.4x | 205.5x | 47.5x |
| zenfmt vs anydoc | 14 | 6.9x | 7.9x | 10.1x |
| zenfmt vs pandoc | 6 | 18.2x | 16.5x | 16.6x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
