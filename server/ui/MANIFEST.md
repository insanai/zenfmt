# Committed interface artifacts

SHA-256 digests of the committed interface assets. The embedded stylesheet
digest is verified by a unit test in `server/src/ui.zig`; a regeneration is
a reviewed diff of file plus digest (ZDS 0016, Supply chain).

| File | SHA-256 |
| --- | --- |
| `assets/zenfmt-ui.css` | `3366788f1976e8060c5265354411022ed073d77ebe374edf303cb8c3becccf20` |
| `assets/daisyui-5.0.45.css` | `33503bcb77d31db9600a0acadf428eaa4817e9a17be359ad2b6e031b6f83d92e` |
| `assets/layout.css` | `7d3d7236ca7c297fb15895489547b9b7ca402e6386cbc7d94f98694c218dc177` |

`shell/index.html` and `glue/ui.js` are first-party sources reviewed like
any other code; the ui wasm module is built by the graph from
`server/ui/src/` and is not a committed artifact.
