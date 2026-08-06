# Summary

<!-- What does this change decide, document, or implement, and why? -->

## Checklist

- [ ] `zig build test` and `zig build fmt-check` pass.
- [ ] `zig build zds-list` reports no warnings: every record file has a
      `registry.typ` entry and every entry has a record file.
- [ ] ZDS changes follow record 0001: numbers are never reused, lifecycle
      state changes update the record's `zds-*` metadata and its
      `registry.typ` entry together, and a superseding design arrives as a
      new record while the old one moves to `abandoned`.
- [ ] A change to a format plugin carries its mapping table, its deliberate
      omissions, and its round-trip expectations in that plugin's record.
- [ ] A change to `Block`, `Inline`, or their tags has its own ZDS: it
      affects every plugin at once.
- [ ] A construct that is dropped or degraded emits a diagnostic, and the
      diagnostic's code appears in a test.
- [ ] Prose that describes code behavior matches the code as it is today.

## Verification

<!-- Paste the commands you ran and their results. -->
