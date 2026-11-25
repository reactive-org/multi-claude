#!/bin/bash
#
# multi-claude.sh — run multiple Claude accounts side by side: Claude Desktop as
# real, separately-identifiable apps with their own Dock tile, name and icon, and
# Claude Code in the terminal via one config directory per profile.
#
#   multi-claude.sh <profile>         create or update one desktop instance
#   multi-claude.sh                   update every installed instance (post-upgrade)
#   multi-claude.sh --update          same as above
#   multi-claude.sh --list            show profiles and their freshness
#   multi-claude.sh --alias [prof..]  print shell alias lines for the terminal app
#   multi-claude.sh --force ...       rebuild even if already current
#
# A profile covers both apps. Everything but the profile name is derived: the app
# is "Claude <Profile>" and the icon hue is a stable hash of the profile, so each
# instance gets its own colour automatically and re-running always reproduces the
# same one. The terminal side needs no clone — Claude Code keeps each account in
# its own CLAUDE_CONFIG_DIR, so --alias just writes the alias to stdout and you
# save it wherever you keep aliases:
#
#   multi-claude.sh --alias work >> ~/.zshrc
#
# Why this clones the whole app rather than making a launcher stub: the Dock
# tile belongs to the *running* process. A stub that opens /Applications/Claude.app
# leaves both instances sharing Claude's own icon and name. Only a bundle with
# its own identity gets its own tile.
#
set -euo pipefail

SCRIPT_VERSION=1                       # bump to force all instances to rebuild
SRC_APP="/Applications/Claude.app"
APPS_DIR="/Applications"
INSTANCES_ROOT="$HOME/.claude-instances"
CLI_SUBDIR=cli
PB=/usr/libexec/PlistBuddy

# Restricted entitlements: these are team-prefixed and cannot be granted by an
# ad-hoc signature. Leaving them in place makes AMFI refuse to launch the app.
RESTRICTED_ENTITLEMENTS=(
  com.apple.application-identifier
  com.apple.developer.team-identifier
  keychain-access-groups
)

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- derivation

app_name_for()  { # work -> "Claude Work"
  local p="$1"
  printf 'Claude %s' "$(printf '%s' "${p:0:1}" | tr '[:lower:]' '[:upper:]')${p:1}"
}
bundle_id_for() { printf 'com.anthropic.claudefordesktop.%s' "$1"; }
profile_dir_for() { printf '%s/%s' "$INSTANCES_ROOT" "$1"; }

# Claude Code's config dir, kept in a subdirectory because the profile dir root is
# the desktop instance's Electron user-data-dir.
cli_config_dir_for() { printf '%s/%s' "$(profile_dir_for "$1")" "$CLI_SUBDIR"; }
alias_name_for()     { printf 'claude-%s' "$1"; }

# Emitted $HOME-relative so a saved rc file survives a different home directory.
alias_line_for() {
  local d; d=$(cli_config_dir_for "$1")
  printf 'alias %s='"'"'CLAUDE_CONFIG_DIR="%s" claude'"'"'\n' \
    "$(alias_name_for "$1")" "${d/#$HOME/\$HOME}"
}

# Lowercase only, so the alias name, the config path and the MCProfile stamp all
# agree on one spelling (app_name_for still title-cases for the display name).
valid_profile() { [[ "$1" =~ ^[a-z0-9_-]+$ ]]; }

# Stable hue per profile, in [0.6, 5.7] radians. The range deliberately excludes
# ~0 so no instance can come out looking like the real Claude.app.
hue_for() {
  local h; h=$(printf '%s' "$1" | cksum | awk '{print $1}')
  awk -v h="$h" 'BEGIN { printf "%.4f", 0.6 + (h % 5100) / 1000 }'
}

src_version() { $PB -c "Print :CFBundleVersion" "$SRC_APP/Contents/Info.plist" 2>/dev/null; }

# ------------------------------------------------------------------ discovery

# Instances are self-describing: we stamp MCProfile into the bundle rather than
# keeping a side-file that could drift from what is actually installed.
installed_clones() {
  local app p
  for app in "$APPS_DIR"/*.app; do
    [ -e "$app/Contents/Info.plist" ] || continue
    p=$($PB -c "Print :MCProfile" "$app/Contents/Info.plist" 2>/dev/null) || continue
    [ -n "$p" ] && printf '%s\t%s\n' "$p" "$app"
  done
}

# Every profile this machine knows about: desktop bundles plus any profile
# directory, so terminal-only profiles are first-class.
known_profiles() {
  { installed_clones | cut -f1
    for d in "$INSTANCES_ROOT"/*/; do [ -d "$d" ] && basename "$d"; done
  } 2>/dev/null | sort -u
}

clone_is_current() { # <app_path>
  local pl="$1/Contents/Info.plist" sv mc ms
  sv=$(src_version)
  mc=$($PB -c "Print :MCSourceVersion" "$pl" 2>/dev/null) || return 1
  ms=$($PB -c "Print :MCScriptVersion" "$pl" 2>/dev/null) || return 1
  [ "$mc" = "$sv" ] && [ "$ms" = "$SCRIPT_VERSION" ]
}

clone_is_running() { # <bundle_id>
  [ -n "$(lsappinfo find "bundleid=$1" 2>/dev/null | tr -d '[:space:]')" ]
}

# -------------------------------------------------------------------- signing

# Re-sign every Mach-O and nested bundle ad-hoc, inside-out.
#
# This must be exhaustive. macOS enforces that a process and the libraries it
# maps share a Team ID, so a bundle cannot be part Developer-ID and part ad-hoc
# — dyld fails with "different Team IDs". Note the search deliberately does NOT
# filter on the executable bit: Electron ships Mach-O .node addons and .dylibs
# that are mode 644 (node-pty, the Office365 MSAL runtime) and missing them
# breaks those features at runtime, long after launch appears to succeed.
# Deepest-first list of every Mach-O file in the bundle. Split into its own
# function because bash 3.2 (what macOS ships) misparses a case statement
# nested inside a command substitution.
list_macho() { # <app>
  find "$1" -type f ! -path "*/Contents/MacOS/*" 2>/dev/null | while IFS= read -r f; do
    [ -L "$f" ] && continue
    if [[ "$(file -b "$f" 2>/dev/null)" == *Mach-O* ]]; then
      printf '%s\t%s\n' "$(printf '%s' "$f" | awk -F/ '{print NF}')" "$f"
    fi
  done | sort -rn -k1,1 | cut -f2-
}

resign_adhoc() { # <app> <app_entitlements> <helper_entitlements>
  local app="$1" ent_app="$2" ent_helper="$3" f b ent
  local sign=(codesign --force --timestamp=none --options runtime --sign -)

  while IFS= read -r f; do
    "${sign[@]}" "$f" >/dev/null 2>&1 || info "warn: could not sign ${f##*/}"
  done < <(list_macho "$app")

  while IFS= read -r b; do
    ent=""
    if [[ "$b" == *.app || "$b" == *.xpc ]]; then ent="$ent_helper"; fi
    if [ -n "$ent" ]; then
      "${sign[@]}" --entitlements "$ent" "$b" >/dev/null 2>&1 || info "warn: ${b##*/}"
    else
      "${sign[@]}" "$b" >/dev/null 2>&1 || info "warn: ${b##*/}"
    fi
  done < <(find "$app" -depth \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" \) ! -path "$app" 2>/dev/null)

  # Everything in Contents/MacOS needs the app entitlements, not just the one
  # named by CFBundleExecutable. The shim execs the real Claude binary, and that
  # binary is the process that maps the frameworks — so it is the one that needs
  # disable-library-validation. Signing it bare makes dyld fail with
  # "different Team IDs" even though the bundle itself verifies fine.
  for f in "$app/Contents/MacOS/"*; do
    [ -f "$f" ] || continue
    "${sign[@]}" --entitlements "$ent_app" "$f" >/dev/null 2>&1 \
      || info "warn: could not sign ${f##*/}"
  done
  "${sign[@]}" --entitlements "$ent_app" "$app" >/dev/null 2>&1 \
    || die "failed to sign $app"
}

write_entitlements() { # <workdir>
  local w="$1"
  codesign -d --entitlements - --xml "$SRC_APP" > "$w/ent-app.plist" 2>/dev/null \
    || die "could not read entitlements from $SRC_APP"
  local k
  for k in "${RESTRICTED_ENTITLEMENTS[@]}"; do
    $PB -c "Delete :$k" "$w/ent-app.plist" 2>/dev/null || true
  done
  # Without this the ad-hoc bundle cannot load its own frameworks: hardened
  # runtime demands a Team ID match, and ad-hoc signatures have no Team ID.
  $PB -c "Add :com.apple.security.cs.disable-library-validation bool true" "$w/ent-app.plist" 2>/dev/null \
    || $PB -c "Set :com.apple.security.cs.disable-library-validation true" "$w/ent-app.plist"

  cat > "$w/ent-helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST
}

# ----------------------------------------------------------------------- icon

build_icon() { # <workdir> <hue> <dest_icns>
  local w="$1" hue="$2" dest="$3"
  local iconset="$w/icon.iconset"
  rm -rf "$iconset"; mkdir -p "$iconset"
  cat > "$w/mkicon.swift" <<'SWIFT'
import AppKit
import CoreImage
let a = CommandLine.arguments
guard let src = NSImage(contentsOfFile: a[1]) else { fputs("cannot read icns\n", stderr); exit(1) }
let hue = Double(a[2]) ?? 0.0
let outDir = a[3]
guard let rep = src.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) as? NSBitmapImageRep,
      let cg = rep.cgImage else { fputs("no usable representation\n", stderr); exit(1) }
var ci = CIImage(cgImage: cg)
if hue != 0 {
    let f = CIFilter(name: "CIHueAdjust")!
    f.setValue(ci, forKey: kCIInputImageKey)
    f.setValue(hue, forKey: kCIInputAngleKey)
    guard let o = f.outputImage else { fputs("hue filter failed\n", stderr); exit(1) }
    ci = o
}
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
guard let tinted = ctx.createCGImage(ci, from: ci.extent) else { fputs("render failed\n", stderr); exit(1) }
for (px, name) in [(16,"icon_16x16"),(32,"icon_16x16@2x"),(32,"icon_32x32"),(64,"icon_32x32@2x"),
                   (128,"icon_128x128"),(256,"icon_128x128@2x"),(256,"icon_256x256"),
                   (512,"icon_256x256@2x"),(512,"icon_512x512"),(1024,"icon_512x512@2x")] {
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    c.interpolationQuality = .high
    c.draw(tinted, in: CGRect(x: 0, y: 0, width: px, height: px))
    guard let img = c.makeImage() else { continue }
    let r = NSBitmapImageRep(cgImage: img)
    r.size = NSSize(width: px, height: px)
    if let png = r.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
}
SWIFT
  swift "$w/mkicon.swift" "$SRC_APP/Contents/Resources/electron.icns" "$hue" "$iconset" \
    || die "icon generation failed"
  iconutil -c icns "$iconset" -o "$dest" || die "iconutil failed"
}

# ----------------------------------------------------------------------- shim

# A compiled launcher that re-executes the bundle's own Claude binary with
# --user-data-dir baked in, so the app is double-clickable. It must be a real
# Mach-O, not a shell script: a #!/bin/sh main executable does not survive
# signing under hardened runtime. It execs the copy *inside this bundle*, which
# is what keeps the process's identity pointed at this bundle.
build_shim() { # <workdir> <profile_dir> <dest_binary>
  local w="$1" profile_dir="$2" dest="$3"
  cat > "$w/shim.swift" <<SWIFT
import Foundation
let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let real = me.deletingLastPathComponent().appendingPathComponent("Claude").path
var argv = [real, "--user-data-dir=${profile_dir}"]
argv += CommandLine.arguments.dropFirst()
var c: [UnsafeMutablePointer<CChar>?] = argv.map { strdup(\$0) }
c.append(nil)
execv(real, &c)
fputs("multi-claude: exec failed for \\(real)\n", stderr)
exit(1)
SWIFT
  swiftc -O -o "$dest" "$w/shim.swift" 2>/dev/null || die "could not compile shim"
}

# ---------------------------------------------------------------------- build

build_instance() { # <profile>
  local profile="$1"
  local name bid hue profile_dir dest w staged
  name=$(app_name_for "$profile")
  bid=$(bundle_id_for "$profile")
  hue=$(hue_for "$profile")
  profile_dir=$(profile_dir_for "$profile")
  dest="$APPS_DIR/$name.app"

  if clone_is_running "$bid"; then
    die "\"$name\" is running — quit it first (replacing a live bundle corrupts it)"
  fi

  step "Building $name  (profile: $profile, hue: $hue)"
  w=$(mktemp -d); trap 'rm -rf "$w"' RETURN
  staged="$w/$name.app"

  # APFS clonefile: a 656MB bundle copies in well under a second and shares
  # blocks with the original until we modify it.
  info "cloning $SRC_APP"
  cp -Rc "$SRC_APP" "$staged" 2>/dev/null || cp -R "$SRC_APP" "$staged" \
    || die "could not clone $SRC_APP"

  local pl="$staged/Contents/Info.plist"
  info "setting identity"
  $PB -c "Set :CFBundleIdentifier $bid" "$pl"
  # CFBundleName must stay "Claude": Electron derives its helper bundle names
  # from it, and renaming it makes the app die with "Unable to find helper app".
  # CFBundleDisplayName is what the Dock, Finder and Cmd-Tab actually show.
  $PB -c "Set :CFBundleDisplayName $name" "$pl"
  # The real icon comes from Assets.car while this key is present, so replacing
  # electron.icns alone would silently do nothing.
  $PB -c "Delete :CFBundleIconName" "$pl" 2>/dev/null || true
  # Drop URL schemes: a duplicate claude: claim makes which app handles a deep
  # link nondeterministic, and the msauth scheme is bound to the real bundle ID.
  $PB -c "Delete :CFBundleURLTypes" "$pl" 2>/dev/null || true

  info "generating icon"
  build_icon "$w" "$hue" "$staged/Contents/Resources/electron.icns"

  info "compiling launcher"
  mkdir -p "$profile_dir"; chmod 700 "$profile_dir"
  mkdir -p "$profile_dir/$CLI_SUBDIR"; chmod 700 "$profile_dir/$CLI_SUBDIR"
  build_shim "$w" "$profile_dir" "$staged/Contents/MacOS/claude-shim"
  $PB -c "Set :CFBundleExecutable claude-shim" "$pl"

  # Stamp before signing so the stamp is covered by the signature.
  $PB -c "Add :MCProfile string $profile" "$pl" 2>/dev/null || $PB -c "Set :MCProfile $profile" "$pl"
  $PB -c "Add :MCSourceVersion string $(src_version)" "$pl" 2>/dev/null || $PB -c "Set :MCSourceVersion $(src_version)" "$pl"
  $PB -c "Add :MCScriptVersion string $SCRIPT_VERSION" "$pl" 2>/dev/null || $PB -c "Set :MCScriptVersion $SCRIPT_VERSION" "$pl"

  rm -f "$staged/Contents/embedded.provisionprofile"
  xattr -cr "$staged" 2>/dev/null || true

  info "re-signing (ad-hoc, inside-out)"
  write_entitlements "$w"
  resign_adhoc "$staged" "$w/ent-app.plist" "$w/ent-helper.plist"
  codesign --verify --deep --strict "$staged" 2>/dev/null \
    || die "signature verification failed for $name"

  # Atomic install: never leave the user without a working app if this fails.
  info "installing to $dest"
  local backup=""
  if [ -e "$dest" ]; then backup="$dest.mc-old.$$"; mv "$dest" "$backup"; fi
  if mv "$staged" "$dest"; then
    [ -n "$backup" ] && rm -rf "$backup"
  else
    [ -n "$backup" ] && mv "$backup" "$dest"
    die "could not install $dest"
  fi

  touch "$dest"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$dest" 2>/dev/null || true
  printf '\033[32m  ✓ %s\033[0m  → %s\n' "$name" "$profile_dir"
  printf '    %s\n' "$(alias_line_for "$profile")"
  printf '    save it with: %s --alias %s >> ~/.zshrc\n' "$(basename "$0")" "$profile"
}

# ----------------------------------------------------------------------- main

FORCE=0
PROFILES=()
for arg in "$@"; do
  case "$arg" in
    --force)      FORCE=1 ;;
    --update)     ;;                       # default behaviour with no profiles
    --list)       MODE=list ;;
    --alias)      MODE="alias" ;;
    -h|--help)    awk 'NR>1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*)           die "unknown option: $arg" ;;
    *)            valid_profile "$arg" || die "invalid profile name: $arg (use lowercase letters, digits, - and _)"
                  PROFILES+=("$arg") ;;
  esac
done

# --alias is pure output: it must not require Claude.app to be installed, since a
# profile can be terminal-only.
if [ "${MODE:-}" = alias ]; then
  if [ ${#PROFILES[@]} -eq 0 ]; then
    profiles=$(known_profiles)
    [ -z "$profiles" ] && die "no profiles yet — run: $(basename "$0") --alias <profile>"
    while IFS= read -r p; do
      [ -z "${p:-}" ] && continue
      alias_line_for "$p"
    done <<< "$profiles"
  else
    for profile in "${PROFILES[@]}"; do alias_line_for "$profile"; done
  fi
  exit 0
fi

[ -d "$SRC_APP" ] || die "$SRC_APP not found"
mkdir -p "$INSTANCES_ROOT"; chmod 700 "$INSTANCES_ROOT"

if [ "${MODE:-}" = list ]; then
  printf '%-14s %-26s %-10s %-6s %s\n' PROFILE APP STATUS CLI VERSION
  while IFS= read -r p; do
    [ -z "${p:-}" ] && continue
    app="$APPS_DIR/$(app_name_for "$p").app"
    if [ -d "$app" ]; then
      v=$($PB -c "Print :MCSourceVersion" "$app/Contents/Info.plist" 2>/dev/null)
      clone_is_current "$app" && s=current || s=STALE
      a=$(basename "$app")
    else
      a=-; s=-; v=-
    fi
    [ -d "$(cli_config_dir_for "$p")" ] && c=yes || c=-
    printf '%-14s %-26s %-10s %-6s %s\n' "$p" "$a" "$s" "$c" "$v"
  done < <(known_profiles)
  exit 0
fi

if [ ${#PROFILES[@]} -eq 0 ]; then
  # No profile given: refresh everything that is out of date. This is the
  # command to run after Claude auto-updates, since ShipIt replaces
  # /Applications/Claude.app in place and leaves every instance stale.
  rows=$(installed_clones)
  [ -z "$rows" ] && die "no instances installed yet — run: $(basename "$0") <profile>"
  built=0
  while IFS=$'\t' read -r p app; do
    [ -z "${p:-}" ] && continue
    if [ "$FORCE" -eq 0 ] && clone_is_current "$app"; then
      info "$(basename "$app") already current"
    else
      build_instance "$p"; built=$((built+1))
    fi
  done <<< "$rows"
  [ "$built" -gt 0 ] && killall Dock 2>/dev/null || true
  exit 0
fi

for profile in "${PROFILES[@]}"; do
  name=$(app_name_for "$profile")
  if [ "$FORCE" -eq 0 ] && [ -d "$APPS_DIR/$name.app" ] && clone_is_current "$APPS_DIR/$name.app"; then
    info "$name already current (Claude $(src_version)) — use --force to rebuild"
    continue
  fi
  build_instance "$profile"
done
killall Dock 2>/dev/null || true

cat <<'NOTE'

Notes:
  * These instances are ad-hoc signed copies, so Claude's own auto-updater will
    not update them. After Claude Desktop upgrades, re-run this script with no
    arguments to rebuild them all.
  * Expect one "Claude Safe Storage" Keychain prompt per instance the first time
    it runs, and again after each Claude upgrade — choose "Always Allow".
    Claude keys that item to the signing identity, and an ad-hoc signature is
    pinned to the bundle's exact contents, which change when Claude updates.
    Re-running this script on the same Claude version does not re-prompt.
  * The terminal side is independent of these bundles: nothing is cloned or
    re-signed, so the aliases keep working across Claude Code upgrades, and a
    profile can be terminal-only. Print one with:

      multi-claude.sh --alias <profile> >> ~/.zshrc

    The first run of a new alias walks through login for that account.
NOTE
