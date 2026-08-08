# Native bridge staging directory

This directory holds the packaged zenfmt bridge shared library
(`libzenfmt_py.so` / `libzenfmt_py.dylib` / `zenfmt_py.dll`).

- In a **wheel**, the Hatchling build hook places the bridge here at build
  time; it ships inside the wheel and nowhere else.
- In a **development checkout**, run `zig build python-sync` to build the
  host bridge and stage it here for the editable install. The binary is
  gitignored.

The runtime loader opens only this directory's exact per-platform
filename by absolute package path. It never searches `PATH`, the current
directory, `zig-out`, or any environment override.
