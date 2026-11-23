# multi-claude

Run multiple Claude Desktop accounts side by side on macOS, each as a real app
with its own Dock tile, name and icon.

```sh
./multi-claude.sh work      # create or update one instance
./multi-claude.sh           # update all instances (run after Claude upgrades)
./multi-claude.sh --list    # show instances and whether they're current
```

One argument. The app name (`Claude Work`) and icon hue are derived from the
profile name, so colours are distinct and stable across rebuilds.

Profiles live in `~/.claude-instances/<profile>` and are never touched by the
script. `/Applications/Claude.app` is left alone.

## How it works

Each instance is a clone of `Claude.app` with its own bundle ID, display name
and hue-shifted icon, re-signed ad-hoc, launched through a small compiled shim
that passes `--user-data-dir`.

It clones the whole app rather than shipping a launcher stub because the Dock
tile belongs to the *running* process — a stub that opens `Claude.app` leaves
every instance sharing Claude's own icon and name.

Two constraints are load-bearing:

- **Every** nested Mach-O is re-signed ad-hoc and granted
  `disable-library-validation`. macOS requires a process and its libraries to
  share a Team ID, so a part-Developer-ID bundle dies in dyld with
  "different Team IDs". This includes the mode-644 `.node`/`.dylib` files.
- `CFBundleName` stays `"Claude"` — Electron derives helper bundle names from
  it. Only `CFBundleDisplayName` changes, which is what the Dock shows.

## Caveats

- **Keychain prompt.** Claude keys its `Claude Safe Storage` item to the
  signing identity, so each instance prompts on first run — choose
  *Always Allow*. Re-running the script does not re-prompt; a Claude upgrade
  does, once per instance.
- **No auto-update.** Ad-hoc copies are ignored by Claude's updater. Re-run
  with no arguments after Claude upgrades.
- **Passkeys and Microsoft SSO may not work.** Ad-hoc signing cannot carry
  Anthropic's team-prefixed `keychain-access-groups`.
- **Deep links** (`claude://`) always open the real `Claude.app`.

Uninstall an instance with `rm -rf "/Applications/Claude <Profile>.app"`; the
profile and the original app are unaffected.

## Requirements

macOS with Xcode Command Line Tools (`swift`, `swiftc`, `codesign`).
