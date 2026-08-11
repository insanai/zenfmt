# Committed interface artifacts

SHA-256 digests of the committed interface assets. The embedded stylesheet
digests are verified by unit tests in `server/src/ui.zig`. A regeneration is
a reviewed diff of file plus digest (ZDS 0016, Supply chain).

| File | SHA-256 |
| --- | --- |
| `assets/daisyui-5.0.45.css` | `33503bcb77d31db9600a0acadf428eaa4817e9a17be359ad2b6e031b6f83d92e` |
| `assets/layout.css` | `153513d57d0d2bf02713928ae89fd02b272f72781d440235d51e8058fa6a69a9` |

`shell/index.html` and `glue/ui.js` are first-party sources reviewed like
any other code; the ui wasm module is built by the graph from
`server/ui/src/` and is not a committed artifact.
