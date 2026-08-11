# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 3.4 | 2.8 | 3.6 |
| | | docling | unsupported | | |
| | | anydoc | 39.7 | 40.4 | 49.6 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.1 | 56.7 | 31.4 |
| book.epub | 545.4560546875KiB | zenfmt | 39.6 | 38.6 | 23.1 |
| | | docling | unsupported | | |
| | | anydoc | 59.2 | 58.9 | 54.1 |
| | | pandoc | 1294.7 | 1284.4 | 269.1 |
| | | zenfmt-python-wheel | 96.3 | 95.0 | 54.2 |
| data.csv | 618.5078125KiB | zenfmt | 53.6 | 52.4 | 41.2 |
| | | docling | 3214.3 | 3205.8 | 565.2 |
| | | anydoc | 82.4 | 81.6 | 70.9 |
| | | pandoc | 831.7 | 821.7 | 290.2 |
| | | zenfmt-python-wheel | 113.3 | 111.9 | 73.5 |
| deck.ppt | 2.4599609375MiB | zenfmt | 8.1 | 7.4 | 7.6 |
| | | docling | unsupported | | |
| | | anydoc | 41.7 | 41.2 | 53.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 65.5 | 64.0 | 35.4 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 3.4 | 2.7 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | failed | | |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.9 | 57.5 | 30.7 |
| letter.odt | 4.1591796875KiB | zenfmt | 2.9 | 2.3 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 41.3 | 40.8 | 47.0 |
| | | pandoc | 33.0 | 19.2 | 41.5 |
| | | zenfmt-python-wheel | 59.1 | 57.7 | 31.1 |
| memo.doc | 32KiB | zenfmt | 2.9 | 2.3 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | 40.6 | 40.2 | 47.2 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.8 | 57.4 | 30.9 |
| notes.rtf | 32.376953125KiB | zenfmt | 3.1 | 2.6 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | 40.1 | 39.7 | 46.4 |
| | | pandoc | 43.0 | 33.1 | 104.5 |
| | | zenfmt-python-wheel | 59.0 | 57.6 | 30.9 |
| page.html | 832.595703125KiB | zenfmt | 36.3 | 35.2 | 23.3 |
| | | docling | 3314.5 | 3276.2 | 392.6 |
| | | anydoc | unsupported | | |
| | | pandoc | 1290.8 | 1278.1 | 426.5 |
| | | zenfmt-python-wheel | 93.7 | 92.3 | 53.9 |
| report.docx | 33.5693359375KiB | zenfmt | 4.3 | 3.8 | 3.4 |
| | | docling | 2475.2 | 2464.2 | 373.2 |
| | | anydoc | 40.2 | 39.9 | 48.0 |
| | | pandoc | 55.6 | 40.3 | 108.4 |
| | | zenfmt-python-wheel | 60.5 | 59.0 | 31.1 |
| sheet.ods | 6.107421875KiB | zenfmt | 3.1 | 2.6 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 40.4 | 40.0 | 47.4 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 59.3 | 57.8 | 31.0 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 3.7 | 3.2 | 3.2 |
| | | docling | 2423.1 | 2414.7 | 370.0 |
| | | anydoc | 39.7 | 39.3 | 47.2 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 59.9 | 58.4 | 31.1 |
| slides.odp | 466.00390625KiB | zenfmt | 15.6 | 15.0 | 4.4 |
| | | docling | unsupported | | |
| | | anydoc | 47.5 | 47.0 | 54.2 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 71.5 | 70.1 | 32.2 |
| slides.pptx | 633.080078125KiB | zenfmt | 19.0 | 18.4 | 4.4 |
| | | docling | 2744.6 | 2736.1 | 379.2 |
| | | anydoc | 46.3 | 45.9 | 49.4 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 75.3 | 73.8 | 32.3 |
| spec.pdf | 12.953125KiB | zenfmt | 2.7 | 2.3 | 3.2 |
| | | docling | unsupported | | |
| | | anydoc | 39.6 | 40.4 | 48.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.8 | 57.3 | 31.0 |
| table.xls | 13KiB | zenfmt | 2.8 | 2.4 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 39.8 | 39.3 | 47.0 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 59.2 | 57.8 | 31.0 |

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
| zenfmt vs docling | 5 | 195.8x | 209.1x | 47.6x |
| zenfmt vs anydoc | 14 | 7.0x | 7.9x | 10.2x |
| zenfmt vs pandoc | 6 | 18.1x | 16.6x | 16.6x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
