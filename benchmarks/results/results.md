# zenfmt conversion benchmark

Median of 5 runs per tool per file (one discarded warm-up); child
process wall clock, CPU (user+sys) and peak RSS from `wait4` rusage.
`unsupported` means the tool's documentation lists no reader for the
format; `failed` means it exited non-zero.

| file | size | tool | wall ms | cpu ms | peak RSS MB |
|---|---:|---|---:|---:|---:|
| article.pdf | 18.369140625KiB | zenfmt | 4.7 | 3.7 | 3.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 41.6 | 42.5 | 49.7 |
| | | zenfmt-python-wheel | 57.7 | 56.3 | 31.2 |
| book.epub | 545.4560546875KiB | zenfmt | 30.3 | 29.4 | 22.9 |
| | | pandoc | 1297.9 | 1280.1 | 269.1 |
| | | anydoc | 61.0 | 60.4 | 54.0 |
| | | zenfmt-python-wheel | 136.9 | 135.4 | 54.6 |
| data.csv | 618.5078125KiB | zenfmt | 75.7 | 74.5 | 41.0 |
| | | pandoc | 831.2 | 814.8 | 290.2 |
| | | anydoc | 83.8 | 82.8 | 68.0 |
| | | zenfmt-python-wheel | 1331.2 | 1329.5 | 73.5 |
| deck.ppt | 2.4599609375MiB | zenfmt | 6.6 | 5.8 | 7.4 |
| | | pandoc | unsupported | | |
| | | anydoc | 42.0 | 41.5 | 53.9 |
| | | zenfmt-python-wheel | 72.4 | 71.0 | 35.2 |
| grid.xlsb | 8.9462890625KiB | zenfmt | 2.3 | 1.7 | 2.8 |
| | | pandoc | unsupported | | |
| | | anydoc | failed | | |
| | | zenfmt-python-wheel | 57.3 | 56.0 | 30.7 |
| letter.odt | 4.1591796875KiB | zenfmt | 2.3 | 1.7 | 2.9 |
| | | pandoc | 35.8 | 19.9 | 41.6 |
| | | anydoc | 41.1 | 40.8 | 47.0 |
| | | zenfmt-python-wheel | 57.5 | 56.0 | 30.8 |
| memo.doc | 32KiB | zenfmt | 2.4 | 1.8 | 2.9 |
| | | pandoc | unsupported | | |
| | | anydoc | 41.1 | 40.7 | 47.2 |
| | | zenfmt-python-wheel | 57.8 | 56.3 | 30.7 |
| notes.rtf | 32.376953125KiB | zenfmt | 2.8 | 2.1 | 2.8 |
| | | pandoc | 51.0 | 34.5 | 104.5 |
| | | anydoc | 43.1 | 42.7 | 46.4 |
| | | zenfmt-python-wheel | 57.6 | 56.2 | 30.7 |
| page.html | 832.595703125KiB | zenfmt | 26.1 | 25.2 | 23.1 |
| | | pandoc | 1282.5 | 1261.9 | 426.5 |
| | | anydoc | unsupported | | |
| | | zenfmt-python-wheel | 132.4 | 130.8 | 54.3 |
| report.docx | 33.5693359375KiB | zenfmt | 2.9 | 2.3 | 3.2 |
| | | pandoc | 50.3 | 40.3 | 108.4 |
| | | anydoc | 41.4 | 40.9 | 48.1 |
| | | zenfmt-python-wheel | 60.7 | 59.3 | 31.0 |
| sheet.ods | 6.107421875KiB | zenfmt | 2.5 | 1.9 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 41.0 | 40.7 | 47.5 |
| | | zenfmt-python-wheel | 59.0 | 57.5 | 30.8 |
| sheet.xlsx | 12.935546875KiB | zenfmt | 2.9 | 2.2 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 40.8 | 40.5 | 47.3 |
| | | zenfmt-python-wheel | 61.3 | 59.9 | 31.0 |
| slides.odp | 466.00390625KiB | zenfmt | 7.7 | 7.1 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 49.3 | 48.9 | 54.5 |
| | | zenfmt-python-wheel | 76.2 | 74.8 | 31.9 |
| slides.pptx | 633.080078125KiB | zenfmt | 7.3 | 6.6 | 4.2 |
| | | pandoc | unsupported | | |
| | | anydoc | 47.3 | 47.0 | 49.3 |
| | | zenfmt-python-wheel | 79.5 | 78.3 | 32.2 |
| spec.pdf | 12.953125KiB | zenfmt | 2.4 | 1.8 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 40.6 | 41.2 | 48.9 |
| | | zenfmt-python-wheel | 58.1 | 56.7 | 30.8 |
| table.xls | 13KiB | zenfmt | 2.6 | 1.9 | 3.0 |
| | | pandoc | unsupported | | |
| | | anydoc | 39.9 | 39.5 | 47.0 |
| | | zenfmt-python-wheel | 60.0 | 58.6 | 30.8 |

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
| zenfmt vs pandoc | 6 | 21.7x | 20.4x | 17.2x |
| zenfmt vs anydoc | 14 | 8.8x | 10.7x | 10.6x |
| zenfmt vs zenfmt-python-wheel | 16 | 15.3x | 18.1x | 7.0x |

Ratios are the other tool's median divided by zenfmt's: above 1.0 means zenfmt is faster or smaller on the shared files.
