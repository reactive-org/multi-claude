# multi-claude

Run multiple Claude accounts side by side on macOS — **Claude Desktop** as real
apps with their own Dock tile, name and icon, and **Claude Code** in the terminal
with its own login per account.

```sh
./multi-claude.sh work                  # create or update one desktop instance
./multi-claude.sh                       # update all instances (after Claude upgrades)
./multi-claude.sh --list                # show profiles and whether they're current
./multi-claude.sh --alias work >> ~/.zshrc   # terminal alias for the same profile
```

One argument. A profile covers both apps: the app name (`Claude Work`) and icon
hue are derived from the profile name, so colours are distinct and stable across
rebuilds, and the terminal alias (`claude-work`) points at the same profile.

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

## Terminal (Claude Code)

The CLI needs no clone — Claude Code already supports one config directory per
account, so a profile just gets a second directory:

```
~/.claude-instances/work/        desktop (Electron user-data-dir)
~/.claude-instances/work/cli/    CLAUDE_CONFIG_DIR for the terminal app
```

`--alias` writes the line to stdout and nothing else, so you can save it wherever
you keep aliases (`>> ~/.zshrc`, a file in `~/.config`, …). With no profile given
it prints one line per known profile:

```sh
alias claude-work='CLAUDE_CONFIG_DIR="$HOME/.claude-instances/work/cli" claude'
```

The first `claude-work` run walks through login for that account. The isolation is
real rather than cosmetic: `CLAUDE_CONFIG_DIR` relocates every `~/.claude` path
and `~/.claude.json`, and on macOS the Keychain credential entry is
[keyed to that directory](https://code.claude.com/docs/en/authentication#credential-management),
so each alias reads its own login. Nothing here is signed or cloned, so the
aliases survive Claude Code upgrades, and a profile can be terminal-only — the
desktop bundle is optional.

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
- **A global `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` wins.** Those outrank
  the per-directory login, so every alias would use that one credential. Unset
  them, or set them per alias.
- **Two Console *keyless* sign-ins are not isolated by the config dir.** That kind
  of sign-in lives in `~/.config/anthropic`, outside `CLAUDE_CONFIG_DIR`, and
  needs `ANTHROPIC_PROFILE` as well. claude.ai subscription logins isolate fine.

Uninstall a desktop instance with `rm -rf "/Applications/Claude <Profile>.app"`;
the profile and the original app are unaffected. Drop a terminal identity with
`rm -rf ~/.claude-instances/<profile>/cli` and delete its alias line.

## Requirements

macOS with Xcode Command Line Tools (`swift`, `swiftc`, `codesign`).
