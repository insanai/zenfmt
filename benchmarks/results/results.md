# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 3.3 | 2.7 | 3.6 |
| | | docling | unsupported | | |
| | | anydoc | 41.7 | 42.5 | 49.7 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.9 | 57.4 | 31.3 |
| book.epub | 545.4560546875KiB | zenfmt | 39.9 | 38.9 | 23.1 |
| | | docling | unsupported | | |
| | | anydoc | 61.1 | 60.5 | 54.1 |
| | | pandoc | 1308.0 | 1294.0 | 269.1 |
| | | zenfmt-python-wheel | 97.5 | 96.1 | 54.2 |
| data.csv | 618.5078125KiB | zenfmt | 53.9 | 52.7 | 41.2 |
| | | docling | 3214.9 | 3204.7 | 565.3 |
| | | anydoc | 84.4 | 83.7 | 71.0 |
| | | pandoc | 824.2 | 813.4 | 290.3 |
| | | zenfmt-python-wheel | 112.1 | 110.7 | 73.2 |
| deck.ppt | 2.4599609375MiB | zenfmt | 8.1 | 7.4 | 7.6 |
| | | docling | unsupported | | |
| | | anydoc | 42.0 | 41.5 | 53.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 63.7 | 62.2 | 35.3 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 3.0 | 2.4 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | failed | | |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.8 | 57.4 | 30.8 |
| letter.odt | 4.1591796875KiB | zenfmt | 2.9 | 2.3 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 39.4 | 39.0 | 47.0 |
| | | pandoc | 32.5 | 18.8 | 41.6 |
| | | zenfmt-python-wheel | 58.6 | 57.1 | 30.9 |
| memo.doc | 32KiB | zenfmt | 2.9 | 2.3 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | 40.0 | 39.5 | 47.2 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.8 | 57.3 | 31.0 |
| notes.rtf | 32.376953125KiB | zenfmt | 3.4 | 2.8 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 41.1 | 40.7 | 46.4 |
| | | pandoc | 43.0 | 32.5 | 104.5 |
| | | zenfmt-python-wheel | 58.6 | 57.1 | 30.9 |
| page.html | 832.595703125KiB | zenfmt | 36.4 | 35.4 | 23.4 |
| | | docling | 3091.7 | 3081.5 | 392.0 |
| | | anydoc | unsupported | | |
| | | pandoc | 1287.6 | 1274.2 | 426.5 |
| | | zenfmt-python-wheel | 93.1 | 91.6 | 53.9 |
| report.docx | 33.5693359375KiB | zenfmt | 4.3 | 3.8 | 3.4 |
| | | docling | 2473.7 | 2463.5 | 373.3 |
| | | anydoc | 41.2 | 40.7 | 48.0 |
| | | pandoc | 45.0 | 39.6 | 108.4 |
| | | zenfmt-python-wheel | 60.2 | 58.8 | 31.2 |
| sheet.ods | 6.107421875KiB | zenfmt | 3.2 | 2.6 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 40.0 | 39.5 | 47.4 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.3 | 56.9 | 30.9 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 3.8 | 3.2 | 3.2 |
| | | docling | 2432.4 | 2422.4 | 370.0 |
| | | anydoc | 40.3 | 39.7 | 47.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 59.9 | 58.4 | 31.0 |
| slides.odp | 466.00390625KiB | zenfmt | 15.7 | 15.0 | 4.4 |
| | | docling | unsupported | | |
| | | anydoc | 48.6 | 48.0 | 54.4 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 71.1 | 69.6 | 32.3 |
| slides.pptx | 633.080078125KiB | zenfmt | 19.1 | 18.3 | 4.4 |
| | | docling | 2742.7 | 2736.1 | 379.1 |
| | | anydoc | 46.6 | 46.1 | 49.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 74.7 | 73.3 | 32.3 |
| spec.pdf | 12.953125KiB | zenfmt | 2.8 | 2.3 | 3.2 |
| | | docling | unsupported | | |
| | | anydoc | 40.8 | 41.4 | 48.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.4 | 57.0 | 31.0 |
| table.xls | 13KiB | zenfmt | 3.0 | 2.4 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 40.5 | 40.0 | 47.0 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 58.7 | 57.3 | 31.0 |

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
| zenfmt vs docling | 5 | 192.1x | 206.5x | 47.5x |
| zenfmt vs anydoc | 14 | 7.0x | 7.9x | 10.2x |
| zenfmt vs pandoc | 6 | 17.1x | 16.1x | 16.6x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
