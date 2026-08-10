# The interface stylesheet

`assets/zenfmt-ui.css` is a committed artifact assembled offline from two
inputs, in order:

1. `assets/daisyui-5.0.45.css` — the official full daisyUI 5.0.45 CSS
   build, vendored verbatim from
   `https://cdn.jsdelivr.net/npm/daisyui@5.0.46/daisyui.css`
   (the 5.0.46 package ships the 5.0.45-labeled build). It carries the
   complete component set and the `light` and `dark` themes selected by
   the `data-theme` attribute, which the glue sets on the module's
   `theme_apply` command. It contains no JavaScript.
2. `assets/layout.css` — the first-party reset and the handful of layout
   utilities (`zf-*` classes) the ui module's markup uses.

Regeneration is a maintainer action, never a CI step:

```sh
curl -sL -o server/ui/assets/daisyui-5.0.45.css \
  "https://cdn.jsdelivr.net/npm/daisyui@5.0.46/daisyui.css"
cat server/ui/assets/daisyui-5.0.45.css server/ui/assets/layout.css \
  > server/ui/assets/zenfmt-ui.css
shasum -a 256 server/ui/assets/*.css   # update MANIFEST.md and the
                                       # digest test in server/src/ui.zig
```

ZDS 0016 anticipates a pruned Tailwind 4 + daisyUI standalone-CLI build in
place of the full vendored sheet; adopting one changes only this file, the
artifact, `MANIFEST.md`, and the pinned digest. CI never runs npm or a CSS
toolchain either way.
