# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 5.5 | 4.5 | 3.6 |
| | | docling | unsupported | | |
| | | anydoc | 66.0 | 67.3 | 49.6 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 92.7 | 90.9 | 31.4 |
| book.epub | 545.4560546875KiB | zenfmt | 128.8 | 127.1 | 23.1 |
| | | docling | unsupported | | |
| | | anydoc | 98.2 | 97.9 | 54.1 |
| | | pandoc | 2006.6 | 1995.0 | 269.0 |
| | | zenfmt-python-wheel | 220.2 | 218.3 | 54.2 |
| data.csv | 618.5078125KiB | zenfmt | 2086.0 | 2084.2 | 41.2 |
| | | docling | 4922.9 | 4908.8 | 565.2 |
| | | anydoc | 130.2 | 129.7 | 71.0 |
| | | pandoc | 1275.0 | 1260.8 | 290.3 |
| | | zenfmt-python-wheel | 2174.5 | 2172.1 | 73.3 |
| deck.ppt | 2.4599609375MiB | zenfmt | 29.1 | 27.9 | 7.5 |
| | | docling | unsupported | | |
| | | anydoc | 66.5 | 66.2 | 53.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 116.5 | 114.7 | 35.5 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 4.7 | 3.8 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | failed | | |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 93.8 | 92.0 | 30.9 |
| letter.odt | 4.1591796875KiB | zenfmt | 4.6 | 3.7 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 64.8 | 64.6 | 47.0 |
| | | pandoc | 41.2 | 27.9 | 41.6 |
| | | zenfmt-python-wheel | 93.4 | 91.5 | 30.9 |
| memo.doc | 32KiB | zenfmt | 5.9 | 4.9 | 3.0 |
| | | docling | unsupported | | |
| | | anydoc | 63.9 | 63.7 | 47.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 92.2 | 90.3 | 31.1 |
| notes.rtf | 32.376953125KiB | zenfmt | 5.1 | 4.2 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 66.0 | 65.7 | 46.4 |
| | | pandoc | 66.4 | 48.6 | 104.5 |
| | | zenfmt-python-wheel | 92.6 | 90.8 | 30.9 |
| page.html | 832.595703125KiB | zenfmt | 122.0 | 120.4 | 23.3 |
| | | docling | 4820.2 | 4811.3 | 392.7 |
| | | anydoc | unsupported | | |
| | | pandoc | 1992.4 | 1978.5 | 426.5 |
| | | zenfmt-python-wheel | 212.1 | 210.3 | 54.0 |
| report.docx | 33.5693359375KiB | zenfmt | 9.3 | 8.4 | 3.4 |
| | | docling | 3818.4 | 3804.5 | 373.4 |
| | | anydoc | 64.2 | 63.9 | 48.0 |
| | | pandoc | 75.6 | 59.8 | 108.4 |
| | | zenfmt-python-wheel | 99.3 | 97.5 | 31.2 |
| sheet.ods | 6.107421875KiB | zenfmt | 6.5 | 5.5 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 64.8 | 64.5 | 47.5 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 94.7 | 93.0 | 31.0 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 10.1 | 9.1 | 3.2 |
| | | docling | 3711.2 | 3698.0 | 370.0 |
| | | anydoc | 65.1 | 64.9 | 47.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 97.1 | 95.2 | 31.1 |
| slides.odp | 466.00390625KiB | zenfmt | 35.2 | 34.2 | 4.4 |
| | | docling | unsupported | | |
| | | anydoc | 77.4 | 77.0 | 54.5 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 123.8 | 121.9 | 32.3 |
| slides.pptx | 633.080078125KiB | zenfmt | 42.5 | 41.2 | 4.4 |
| | | docling | 4242.2 | 4229.3 | 379.1 |
| | | anydoc | 72.9 | 72.6 | 49.3 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 129.4 | 127.6 | 32.3 |
| spec.pdf | 12.953125KiB | zenfmt | 5.1 | 4.0 | 3.2 |
| | | docling | unsupported | | |
| | | anydoc | 65.0 | 66.0 | 48.9 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 93.0 | 91.2 | 31.0 |
| table.xls | 13KiB | zenfmt | 8.8 | 7.8 | 3.1 |
| | | docling | unsupported | | |
| | | anydoc | 63.7 | 63.5 | 47.1 |
| | | pandoc | unsupported | | |
| | | zenfmt-python-wheel | 96.6 | 94.8 | 31.1 |

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
| zenfmt vs docling | 5 | 67.3x | 70.7x | 47.6x |
| zenfmt vs anydoc | 14 | 4.1x | 4.6x | 10.2x |
| zenfmt vs pandoc | 6 | 7.2x | 6.8x | 16.6x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
