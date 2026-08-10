# Committed interface artifacts

SHA-256 digests of the committed interface assets. The embedded stylesheet
digest is verified by a unit test in `server/src/ui.zig`; a regeneration is
a reviewed diff of file plus digest (ZDS 0016, Supply chain).

| File | SHA-256 |
| --- | --- |
| `assets/zenfmt-ui.css` | `47cd982f46d31034f114e5c6c43a30dcec6e27e1dbb692c2f99038f83086629a` |
| `assets/daisyui-5.0.45.css` | `33503bcb77d31db9600a0acadf428eaa4817e9a17be359ad2b6e031b6f83d92e` |
| `assets/layout.css` | `d80d87004b998d2241b4316ec0e85aed1e79385b36f658986679a8c44583230f` |

`shell/index.html` and `glue/ui.js` are first-party sources reviewed like
any other code; the ui wasm module is built by the graph from
`server/ui/src/` and is not a committed artifact.
