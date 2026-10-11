#!/bin/zsh
# Renders docs/menu-light.png and docs/menu-dark.png from demo data, never your real accounts.
# Needs no Screen Recording permission: the harness draws its own menu windows into images.
# A Claude Switcher icon flashes in the menu bar for a few seconds while it runs.
set -euo pipefail
HERE="${0:A:h}"
ROOT="${HERE:h:h}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

perl -0pe '
  s/private //g;
  s/(    static func latest\(for account: Account\) -> Usage\? \{\n)/    static func latest(for account: Account) -> Usage? { demoUsage[account.folder] }\n    static func realLatest(for account: Account) -> Usage? {\n/;
  s/\nif CommandLine\.arguments\.contains\("--dump"\).*/\n/s;
' "$ROOT/main.swift" > "$WORK/main.swift"
cat "$HERE/harness.swift" >> "$WORK/main.swift"

swiftc -swift-version 5 "$WORK/main.swift" -o "$WORK/shot"
"$WORK/shot" "$ROOT/docs"
"$WORK/shot" "$ROOT/docs" --dark
