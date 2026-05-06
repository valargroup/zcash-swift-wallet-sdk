#!/usr/bin/env bash
#
# Lightweight preflight for Valar shielded-vote split PRs before opening or
# updating upstream zcash-swift-wallet-sdk PRs.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f "$HOME/.cargo/env" ]]; then
    # Needed when invoked from shells that do not load the Rust toolchain path.
    # shellcheck disable=SC1090
    source "$HOME/.cargo/env"
fi

usage() {
    cat <<'USAGE'
Usage: Scripts/shielded-vote-preflight.sh [base-ref]

Runs blocking checks:
  - cargo fmt --all -- --check
  - cargo clippy --all-targets -- -D warnings
  - cargo metadata --locked --format-version 1
  - swiftlint lint --quiet, only when Swift files changed

Then runs advisory diff scans for shielded-vote review polish. Advisory
findings are warnings only; they never change this script's exit code.

Set SHIELDED_VOTE_PREFLIGHT_ADVISORY_ONLY=1 to skip blocking checks when
developing the advisory scanner itself.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

section() {
    printf '\n==> %s\n' "$1"
}

resolve_default_base_ref() {
    local pr_base

    if command -v gh >/dev/null 2>&1; then
        pr_base="$(gh pr view --json baseRefName --jq .baseRefName 2>/dev/null || true)"
        if [[ -n "$pr_base" && "$pr_base" != "null" ]]; then
            for candidate in "upstream/$pr_base" "origin/$pr_base" "$pr_base"; do
                if git rev-parse --verify --quiet "$candidate" >/dev/null; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
            done
        fi
    fi

    for candidate in upstream/main origin/main upstream/shielded-vote-2.4.10 origin/shielded-vote-2.4.10 origin/HEAD main; do
        if git rev-parse --verify --quiet "$candidate" >/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

base_ref="${1:-}"
if [[ -z "$base_ref" ]]; then
    if ! base_ref="$(resolve_default_base_ref)"; then
        echo "error: could not determine a base ref. Pass one explicitly, for example origin/main." >&2
        exit 2
    fi
fi

if ! git rev-parse --verify --quiet "$base_ref" >/dev/null; then
    echo "error: base ref '$base_ref' is not available locally." >&2
    exit 2
fi

merge_base="$(git merge-base "$base_ref" HEAD)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/shielded-vote-preflight.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

changed_files="$tmp_dir/changed-files.txt"
git diff --name-only --diff-filter=ACMR "$merge_base" > "$changed_files"

section "Preflight scope"
printf 'Base ref:   %s\n' "$base_ref"
printf 'Merge base: %s\n' "$merge_base"
printf 'Changed tracked files: %s\n' "$(wc -l < "$changed_files" | tr -d ' ')"

blocking_status=0

run_blocking() {
    local label="$1"
    shift

    section "$label"
    if "$@"; then
        printf 'ok: %s\n' "$label"
    else
        local status=$?
        printf 'failed: %s (exit %s)\n' "$label" "$status" >&2
        blocking_status=1
    fi
}

has_changed_swift_files() {
    grep -E '\.swift$' "$changed_files" >/dev/null
}

cargo_metadata_locked() {
    cargo metadata --locked --format-version 1 >/dev/null
}

if [[ "${SHIELDED_VOTE_PREFLIGHT_ADVISORY_ONLY:-0}" == "1" ]]; then
    section "Blocking checks"
    echo "skipped because SHIELDED_VOTE_PREFLIGHT_ADVISORY_ONLY=1"
else
    run_blocking "cargo fmt" cargo fmt --all -- --check
    run_blocking "cargo clippy" cargo clippy --all-targets -- -D warnings
    run_blocking "cargo metadata" cargo_metadata_locked

    if has_changed_swift_files; then
        if command -v swiftlint >/dev/null 2>&1; then
            run_blocking "swiftlint" swiftlint lint --quiet
        else
            section "swiftlint"
            echo "failed: Swift files changed, but swiftlint is not installed or not on PATH" >&2
            blocking_status=1
        fi
    else
        section "swiftlint"
        echo "skipped: no Swift files changed relative to base"
    fi
fi

section "Advisory scans"
advisory_diff="$tmp_dir/advisory.diff"
git diff --unified=0 --no-ext-diff "$merge_base" -- \
    '*.rs' '*.swift' 'Cargo.toml' 'Package.swift' '*.md' '*.yml' '*.yaml' \
    > "$advisory_diff"

perl - "$advisory_diff" <<'PERL'
use strict;
use warnings;

my $file = "";
my $line_no = 0;
my $count = 0;

my %allowed_numeric = map { $_ => 1 } qw(0 1 2 3 4 8 11 16 20 32 43 64 96);
my $ffi_context = qr/(from_raw_parts|extern\s+"C"|unsafe|path|proof|nullifier|root|byte|bytes|len\b|IMT|PIR|leaf|share|commitment|witness|protocol|ffi|Ffi|Base|u8\s*;|chunks_exact|decode_hex|copy_from|field|wire)/i;

sub emit {
    my ($kind, $message, $line) = @_;
    $count++;
    $line =~ s/\s+$//;
    print "[advisory:$kind] $file:$line_no: $message\n";
    print "  $line\n";
}

while (my $raw = <>) {
    chomp $raw;

    if ($raw =~ /^\+\+\+ b\/(.+)/) {
        $file = $1;
        next;
    }

    if ($raw =~ /^@@ .* \+(\d+)(?:,\d+)? @@/) {
        $line_no = $1 - 1;
        next;
    }

    if ($raw =~ /^ /) {
        $line_no++;
        next;
    }

    next unless $raw =~ /^\+/;
    next if $raw =~ /^\+\+\+/;
    $line_no++;

    my $line = substr($raw, 1);
    next if $file eq "";
    next if $file =~ /(\.pb\.swift|\.grpc\.swift|\.generated\.swift)$/i;
    next if $file eq "Scripts/shielded-vote-preflight.sh";
    next if $file eq "docs/shielded-vote-pr-preflight.md";

    if ($file =~ /\.rs$/) {
        my $defines_named_constant = $line =~ /^\s*(?:pub(?:\([^)]*\))?\s+)?(?:const|static)\s+[A-Z][A-Z0-9_]*\s*:/;

        if ($line =~ /\blet\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*unsafe\s*\{[^}]*from_raw_parts\([^,]+,\s*\d+/ &&
            $line !~ /\blet\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*\[u8\s*;\s*\d+\]/) {
            emit("ffi-byte-slice", "fixed-length FFI byte input is copied as an untyped slice; consider binding it to [u8; N] at the boundary", $line);
        }

        if ($line =~ /\blet\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*unsafe\s*\{\s*bytes_from_ptr\([^,]+,\s*\d+\)\s*\}/) {
            emit("ffi-byte-slice", "fixed-length FFI helper output stays untyped; consider converting to [u8; N] before parsing", $line);
        }

        if (!$defines_named_constant) {
            my @numeric_literals = ($line =~ /(?<![A-Za-z0-9_-])(?:0x[0-9A-Fa-f_]+|[0-9][0-9_]*)(?![A-Za-z0-9_])/g);
            for my $literal (@numeric_literals) {
                my $normalized = $literal;
                $normalized =~ s/_//g;

                next if $allowed_numeric{$normalized};

                my $suspicious = 0;
                if ($normalized =~ /^0x/i) {
                    $suspicious = length($normalized) > 4;
                } elsif ($normalized =~ /^(29|252|512|928|968)$/) {
                    $suspicious = 1;
                } elsif ($normalized =~ /^\d+$/ && $normalized >= 100) {
                    $suspicious = 1;
                }

                if ($suspicious && $line =~ $ffi_context) {
                    emit("rust-numeric-literal", "protocol or wire-size numeric literal may need a named constant or derivation", $line);
                    last;
                }
            }
        }
    }

    if ($line =~ /github\.com\/valargroup|github\.com\/valar|valargroup\/.*releases\/download/i) {
        emit("fork-reference", "fork URL or fork release reference should not leak into upstream-ready PRs", $line);
    }

    if ($file =~ /Cargo\.toml$/ && $line =~ /^\s*\[patch\.crates-io\]/) {
        emit("fork-reference", "patch section is acceptable only for fork/local work; upstream-ready PRs should avoid it", $line);
    }

    if ($file =~ /Cargo\.toml$/ && $line =~ /\bbranch\s*=/) {
        emit("fork-reference", "branch-based Cargo refs are not reproducible; use released crates or pinned revs before upstream review", $line);
    }

    if ($line =~ /(Made with Cursor|Generated with Cursor|Codex|ChatGPT|Claude Code|AI-generated|Generated by AI)/i) {
        emit("tool-signature", "remove AI/tool signature text from upstream PR-facing source, docs, or descriptions", $line);
    }

    if ($file =~ /\.(rs|swift)$/ &&
        $line =~ /^\s*\/\/(?![!\/])\s*(Set|Sets|Get|Gets|Return|Returns|Create|Creates|Initialize|Initializes|Assign|Assigns|Call|Calls|Loop|Loops|Increment|Increments|Decrement|Decrements)\b/i &&
        $line !~ /\b(because|why|so that|avoid|ensure|must|SAFETY|invariant|protocol|upstream|compat|lifetime|workaround|intentional)\b/i) {
        emit("comment-intent", "comment may describe obvious mechanics; prefer comments that explain why, invariants, or safety assumptions", $line);
    }
}

if ($count == 0) {
    print "ok: no advisory findings in the tracked diff\n";
} else {
    print "\n$count advisory finding(s). These are warnings only; use reviewer judgment.\n";
}
PERL

section "Result"
if [[ "$blocking_status" -eq 0 ]]; then
    echo "preflight passed"
else
    echo "preflight failed because one or more blocking checks failed" >&2
fi

exit "$blocking_status"
