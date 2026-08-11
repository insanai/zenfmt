# The interface stylesheet

The server embeds two committed stylesheets and serves each at a content
addressed path:

- `assets/daisyui-5.0.45.css` is the official full daisyUI 5.0.45 CSS
   build, vendored verbatim from
   `https://cdn.jsdelivr.net/npm/daisyui@5.0.46/daisyui.css`
   (the 5.0.46 package ships the 5.0.45-labeled build). It carries the
   complete component set and the `light` and `dark` themes selected by
   the `data-theme` attribute, which the glue sets on the module's
   `theme_apply` command. It contains no JavaScript.

- `assets/layout.css` is the first party visual system and responsive
  layout. Its `zf-*` classes use Material style surfaces, state, elevation,
  and interaction sizes with bold editorial typography.

Regeneration is a maintainer action, never a CI step:

```sh
curl -sL -o server/ui/assets/daisyui-5.0.45.css \
  "https://cdn.jsdelivr.net/npm/daisyui@5.0.46/daisyui.css"
shasum -a 256 server/ui/assets/*.css   # update MANIFEST.md and the
                                       # digest test in server/src/ui.zig
```

ZDS 0016 anticipates a pruned Tailwind 4 and daisyUI standalone CLI build in
place of the full vendored sheet. Adopting one changes only this file, the
vendor artifact, `MANIFEST.md`, and its pinned digest. CI never runs npm or a
CSS toolchain either way.
