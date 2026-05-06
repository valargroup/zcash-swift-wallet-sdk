# Shielded-Vote PR Preflight

This preflight is for Valar-maintained `zcash-swift-wallet-sdk` shielded-vote split PRs before opening or updating upstream PRs. It is intentionally lighter than a custom lint framework: established tools may fail the run, while reviewer-style checks stay advisory until they prove low-noise.

Run it from the repo root:

```sh
Scripts/shielded-vote-preflight.sh [base-ref]
```

If `base-ref` is omitted, the script tries the current GitHub PR base first, then local upstream/origin main-style refs. Pass the upstream target explicitly when in doubt, for example `origin/main`.

## Blocking Checks

The script fails only on checks the repo already understands:

- `cargo fmt --all -- --check`
- `cargo clippy --all-targets -- -D warnings`
- `cargo metadata --locked --format-version 1`
- `swiftlint lint --quiet`, only when Swift files changed relative to the base ref

Advisory findings do not affect the exit code.

## Advisory Checks

The script scans the tracked diff for touched files only and prints warnings for patterns that have caused review friction:

- Rust protocol or wire-size numeric literals in FFI/proof/path contexts that may deserve named constants.
- Fixed-length Rust FFI byte inputs copied as untyped slices instead of `[u8; N]` at the unsafe boundary.
- Fork-only references such as `valargroup` release URLs, `[patch.crates-io]`, or branch-based Cargo refs.
- Tool signatures such as `Made with Cursor`, `Codex`, `ChatGPT`, or `Claude Code`.
- Comments that appear to explain obvious mechanics instead of the non-obvious reason, invariant, compatibility note, or safety assumption.

Treat these as prompts for human judgment. For example, `32` may be obvious when it means one canonical field element, while an IMT depth or derived path-byte length should usually have a name such as `NUM_PATH_ELEMENTS` and `PATH_BYTES`.

## Human Checklist

Before asking upstream reviewers to spend time on a split PR:

- Confirm protocol parameters and wire sizes are named or derived from a named constant when the number is not self-evident.
- Check unsafe FFI boundaries: pointer lengths are documented, fixed byte buffers are typed early, and lifetime assumptions are explicit where Swift passes stack or closure state into Rust.
- Check public Swift protocol additions for source compatibility. Prefer a throwing default implementation in a protocol extension when downstream conformers should keep compiling.
- Keep "not found" separate from FFI or decode failure in public result shapes. Use a typed result when callers need to distinguish absence from error.
- Remove fork-only release artifacts, fork binary URLs, branch-based Cargo refs, and local `[patch.crates-io]` entries before upstream review unless the PR is explicitly a non-mergeable preview.
- Keep upstream PR descriptions and comments human and proportional to the diff. Remove tool signatures and comments that only restate the next line of code.

## Why Not More Automation

SwiftLint has a `no_magic_numbers` rule, but it only applies to Swift and would not catch Rust FFI constants. Clippy does not provide the protocol-constant check we need, and broad Clippy `pedantic` or `restriction` groups are too noisy for this repo. Semgrep can support custom Rust and Swift rules, but this v1 keeps custom checks advisory until we know which patterns are stable enough to gate.

References:

- [Clippy lint index](https://rust-lang.github.io/rust-clippy/stable/index.html)
- [Cargo fmt command](https://doc.rust-lang.org/cargo/commands/cargo-fmt.html)
- [SwiftLint no_magic_numbers](https://realm.github.io/SwiftLint/no_magic_numbers.html)
- [Semgrep supported languages](https://semgrep.dev/docs/supported-languages)
