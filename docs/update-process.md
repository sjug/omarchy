# Omarchy update process

This document describes the supported product and desktop-overlay update paths. `omarchy-installation-type` selects exactly one from the root-owned descriptor at `/etc/omarchy/installation.conf`; product packages provide a compatibility fallback for systems installed before that descriptor existed. Conflicting, malformed, or unregistered checkout-only states fail closed with a targeted repair instead of guessing which updater should run.

It covers the blessed update path plus what happens when a product user attempts to bypass it:

1. `omarchy update` — the blessed interactive Omarchy update flow.
2. `sudo pacman -Syu` — guarded by Omarchy and aborted with instructions unless
   the user explicitly bypasses the guard.

The design goal is:

- `omarchy update` owns the visible update pipeline: package transaction,
  migrations, post-update hooks, update-state refresh, and restart checks.
- Migrations run per-user after pacman finishes, because they may need `$HOME`,
  DBus/session state, a graphical session, sudo, or user interaction.
- Users who bypass `omarchy update` are nudged back by the pacman guard; if they
  explicitly bypass it, their session is notified when migrations are pending.

## State and coordination files

| Path | Owner | Purpose |
| --- | --- | --- |
| `${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock` | user | Prevent overlapping update runs. Owned by `omarchy-update-lock`; compatibility wrappers inherit/respect it. |
| `/tmp/omarchy-update.log` | user | Transcript of `omarchy update`, used by `omarchy-update-analyze-logs`. |
| `/etc/omarchy/installation.conf` | root | Installation type and, for a desktop overlay, its owning user and canonical stage ledger. Written as `KEY=value` with bare literal values — it is parsed, never sourced, so quoted shell assignments are rejected. |
| `~/.local/state/omarchy/current/` | user | Generated active theme, selected theme name, and current background symlink. |
| `~/.local/state/omarchy/migrations/` | user | Per-user migration markers. |
| `~/.local/state/omarchy/desktop-overlay-migrations/` | user | Per-user baseline sentinel and markers for the independent desktop-overlay migration stream. |
| `~/.local/state/omarchy/reboot-required` | user | Optional reboot marker checked by `omarchy-update-restart`. |
| `~/.local/state/omarchy/restart-*-required` | user | Optional service/app restart markers checked by `omarchy-update-restart`. The shell needs no marker: it is restarted unconditionally after every update. |

## Migration layout

See [`migrations.md`](../agents/skills/migrations.md) for the full migration model, authoring
guidelines, and troubleshooting notes.

Migrations live in:

```text
migrations/*.sh
```

They run as the current user through:

```bash
omarchy-migrate
```

Completion state is per-user:

```text
~/.local/state/omarchy/migrations/<migration filename>
```

Every user gets a chance to run every migration. Migrations run as the user;
privileged work should invoke the appropriate helper or privilege prompt.
Migrations must be idempotent; if one user already applied a machine-wide repair,
the migration should no-op for other users.

For watchers and diagnostics, `omarchy-migrate --pending` prints pending
migration names and exits `0` when any are pending. When no migrations are
pending, it prints nothing and exits non-zero.

`omarchy-overlay-migrate --pending` reports the same way but separates the two non-zero cases, so a watcher cannot read a broken overlay as a healthy one: `0` when migrations are pending, `1` when none are, and `2` when the query could not be answered at all (a missing baseline sentinel, a non-overlay installation, an unreadable descriptor, or a failure propagated by `omarchy-installation-type` or `omarchy-overlay-stages`). Both commands accept `--check` as an alias for `--pending`.

## Product raw pacman guard

The `omarchy` package installs an ALPM pre-transaction hook alongside its guard
binary:

```text
/usr/share/libalpm/hooks/00-omarchy-update-guard.hook
/usr/bin/omarchy-update-pacman-guard
```

It triggers on package upgrades and runs:

```bash
omarchy-update-pacman-guard
```

The guard detects direct pacman system-upgrade commands like `pacman -Syu` or
`pacman --sync --refresh --sysupgrade`. If the upgrade was not launched by an
Omarchy update command, the hook exits non-zero with `AbortOnFail`, which stops
the transaction before packages are changed.

`omarchy-update-system-pkgs`, `omarchy-refresh-pacman`, `omarchy-reinstall-pkgs`,
`omarchy-channel-set`, and the v4 upgrader run pacman through:

```bash
env OMARCHY_UPDATE_PACMAN=1 pacman ...
```

so the guard allows Omarchy-owned update flows. A user can intentionally bypass
the guard with:

```bash
sudo env OMARCHY_ALLOW_DIRECT_PACMAN=1 pacman -Syu
```

The guard does not start `omarchy update` itself because pacman is already in a
transaction setup path; it only aborts with instructions.

The `omarchy` package also installs ALPM hooks for `omarchy-settings` /
`omarchy-settings-dev` installs and upgrades. The pre-transaction hook runs
`omarchy-hyprland-reload-guard pause` to disable live Hyprland config reloads
while `/usr/share/omarchy/default/hypr/**` is replaced. The post-transaction
hook runs `omarchy-hyprland-reload-guard resume`, forces one `hyprctl reload`,
and restores the session's previous `misc.disable_autoreload` and
`debug.suppress_errors` values.

## Path 1: `omarchy update`

High-level flow:

```text
omarchy-update
  ├─ ensure transcript logging through script(1) → /tmp/omarchy-update.log
  ├─ omarchy-update-lock
  │    └─ acquire the update lock and run omarchy-update inside it
  ├─ omarchy-installation-type
  ├─ product
  │    ├─ omarchy-update-requires-free-space
  │    ├─ confirmation, cache prune, and snapshot
  │    ├─ product checkout/package update, product migrations, hooks, AUR, mise, and orphan handling
  │    └─ log analysis, status refresh, and restart handling
  └─ desktop_overlay
       └─ omarchy-update-overlay
```

The product path retains this flow:

```text
omarchy-update (product)
  ├─ omarchy-update-requires-free-space
  │    ├─ abort below the configured free-space threshold on /
  │    └─ on LVM/XFS, fail closed at 80% thin-pool data or 70% metadata usage
  ├─ confirm unless -y
  ├─ omarchy-update-pkg-prune
  │    └─ trim the pacman cache to two versions per package, deliberately
  │       before the snapshot since the cache lives on the snapshotted subvolume
  ├─ create snapper snapshot (skipped silently without snapper; snapper
  │  installed but unconfigured fails the snapshot loudly, pointing at
  │  install/config/snapper.sh, and the update continues without one)
  ├─ omarchy-update-stay-awake start
  ├─ run package updates, migrations, hooks, and log analysis
  ├─ omarchy-update-status
  │    └─ refresh or clear the shell update indicator
  ├─ omarchy-update-stay-awake stop
  │    └─ release the sleep inhibitor and restore shell idle state, if changed
  └─ omarchy-update-restart
```

Important behavior:

- In dev-link mode, `omarchy update` fast-forwards the active checkout from its
  configured upstream before changing system packages or running migrations.
- `-y` exports `OMARCHY_UPDATE_UNATTENDED=1` — a promise not to ask anything. Steps that would prompt (orphan removal, conflict handoff) report and skip instead of blocking.
- The storage preflight runs before confirmation, package-cache pruning, and snapshot creation. Btrfs systems use only the 10 GiB filesystem free-space check. An LVM/XFS system also queries its configured root thin pool through `sudo lvs` under the C locale and fails closed if the pool cannot be queried or parsed. `OMARCHY_UPDATE_FORCE=1` remains the explicit emergency bypass for both checks.
- The LVM/XFS data gate blocks at 80% because the installed `omarchy-thin` profile asks dmeventd to autoextend at that point. Healthy monitored pools should grow first and fall to roughly 67%; seeing 80% during update preflight means the VG reserve is exhausted, autoextension failed, or monitoring is not working. A benign race while dmeventd extends can block once, so the command asks the user to retry in a minute. At the spike's approximately 50 GiB pool size, a 20% extension is approximately 10 GiB, intentionally matching the filesystem free-space margin.
- The metadata gate blocks earlier at 70% because thin metadata exhaustion has a more difficult and potentially unrepairable recovery path, while metadata consumption follows mappings and fragmentation rather than filesystem bytes and is therefore harder to forecast.
- The free-space requirement uses a 10 GiB threshold and stops the update before confirmation when it is not met. If free space cannot be determined, the check is silently skipped. Set `OMARCHY_UPDATE_FORCE=1` to bypass the check.
- `omarchy update` checks/runs migrations in the same visible terminal via
  `omarchy-migrate` after pacman finishes.
- A failure should leave enough output in `/tmp/omarchy-update.log` and the
  terminal transcript to debug.

### Desktop-overlay path

A desktop overlay is a checkout-backed Omarchy desktop installed without the `omarchy`, `omarchy-dev`, `omarchy-settings`, or `omarchy-settings-dev` product packages. `omarchy overlay setup` records successful stages in `/etc/omarchy/installation.conf`; `omarchy overlay register` adopts an existing overlay only after every named stage passes its read-only probe. Adopting `display-manager` additionally requires the original active rollback transaction, so registration cannot manufacture a meaningless post-install baseline from Omarchy's own SDDM files. Artifact reconciliation requires that same transaction, and setup refuses an already-configured Omarchy greeter when its original transaction is missing. The descriptor also records the owning user, and overlay updates refuse to run as another user.

An existing checkout-backed desktop can be adopted directly from its checkout before its commands are on `PATH`:

```bash
./bin/omarchy-overlay-register core link config audio files connectivity capture power lock session-entry display-manager
```

Omit any stage that is not installed, then add it later with `omarchy overlay setup <stage>...`. A stale, malformed, or obsolete product descriptor can be replaced explicitly with `./bin/omarchy-overlay-register --repair <stage>...`; repair runs the same stage probes before writing the replacement and never guesses from the old descriptor. A desktop overlay registered to another user must be managed as that user; repair does not transfer ownership or relocate their state. Migration baselining is independent of the descriptor: if the per-user `.baseline-established` sentinel is present, repair preserves pending migrations; if the sentinel and markers were removed together, repair establishes a fresh baseline before writing the descriptor.

Display-manager rollback transactions remain under `~/.local/state/omarchy/dev-setup-desktop/display-manager` for compatibility with the original setup command. Each new transaction carries a versioned destination inventory. Legacy records use a frozen historical index mapping; artifact application upgrades that inventory and captures newly managed paths before modifying them. Rollback follows the recorded inventory, including retired SDDM config files, rather than the current managed-path order. Update-time artifacts preserve host autologin configuration. Explicit setup requests authenticated login and keeps any removed autologin file in an announced `autologin-preserved.*` recovery directory inside the transaction, separate from its original rollback baseline.

The shared path validator permits direct `.conf` files under `/etc/sddm.conf.d/` (names beginning with a letter, digit, underscore, or hyphen, followed by those characters or dots), plus `/usr/share/sddm/hyprland.lua`, `/usr/share/sddm/themes/omarchy`, `/usr/local/share/wayland-sessions/omarchy.desktop`, and `/var/lib/sddm/state.conf`. Preflight, inventory reads, and inventory writes all enforce this scope and reject empty or duplicate path lists. Managing anything outside it requires a deliberate validator change and compatibility tests for existing transactions. Retired destinations must remain supported for rollback. Status reporting `display-manager: configured and enabled` describes the integration and service state; it does not certify that host autologin is disabled or that every login requires authentication.

Enrollment does not install `/etc/profile.d/omarchy.sh`. Outside the UWSM session, use the checkout's explicit command paths, for example `~/omarchy/bin/omarchy-overlay-status` or `~/omarchy/bin/omarchy-overlay-setup`, for diagnosis and repair. The default package source is `pkgs.omarchy.org/stable`, independently of the maintained Git branch. Maintainers must qualify checkout updates against those package versions, including Quickshell, before advancing the branch used by clients.

If setup finds an existing runtime link to the same checkout but no descriptor, `setup core` refuses before changing packages or writing a core-only ledger. This is the legacy checkout-desktop shape. Adopt its already-installed stages with the single `./bin/omarchy-overlay-register ...` command above, or use `omarchy overlay setup core link` when completing a genuinely partial new installation.

If an invalid descriptor and missing core packages prevent those probes, run `./bin/omarchy-overlay-setup core --repair`. It restores the absent repository stanza and pinned package key, installs and verifies the core stage, preserves the invalid descriptor as a timestamped backup, and then writes a core-only overlay ledger. It never records core before its package transaction succeeds.

The user-facing `omarchy dev link` and `omarchy dev unlink` commands refuse registered overlays. Overlay setup uses their shared low-level runtime-link writer so `omarchy overlay setup link` remains the supported repair for `/etc/omarchy.conf` without exposing the product development-link lifecycle.

The update sequence is deliberately narrower than the product path:

```text
omarchy-update-overlay
  ├─ ensure transcript logging and acquire the shared update lock when invoked directly
  ├─ validate the overlay descriptor and stage ledger
  ├─ require no tracked checkout changes, an attached branch, and a configured upstream
  ├─ require the per-user overlay migration baseline sentinel
  ├─ preflight every recorded static artifact against the current checkout and host state
  ├─ free-space preflight and confirmation unless -y
  ├─ fetch without credential prompts and with a 30-second bound; allow equal or locally-ahead history; refuse divergence
  ├─ when behind, verify the plain overlay-dispatch marker from the upstream ref before changing HEAD
  ├─ fast-forward and re-exec omarchy-update once from the new revision
  ├─ omarchy-overlay-setup packages <recorded package stages>
  │    └─ one sudo pacman -Syu --needed --noconfirm transaction using the desktop manifest
  ├─ omarchy-overlay-setup artifacts <recorded static stages>
  │    └─ reapply lock, session-entry, and display-manager files without another package transaction; preserve SDDM service, target, and runtime state
  ├─ omarchy-overlay-migrate
  ├─ omarchy-hook post-update
  ├─ print manual omarchy refresh config commands for defaults changed by the checkout update
  ├─ update-indicator refresh; failure warns without invalidating completed package work
  └─ run normal restart checks
```

The overlay updater never creates a snapshot, invokes product migrations, uses the product package conflict/quarantine updater, refreshes user configuration automatically, or reapplies the `files` stage's MIME preference. It also omits the product-only sleep inhibitor, log analysis, standalone keyring bootstrap, AUR update, mise update, and orphan cleanup steps. `omarchy-keyring` belongs to the overlay core package group and is reconciled in the single system package transaction; core reconciliation first restores an absent repository stanza and pinned signing key, while leaving an existing customized stanza unchanged. Foreign AUR packages such as `brave-origin-bin` remain the user's responsibility. Package reconciliation is noninteractive after the update's single confirmation; a package conflict stops safely for manual repair rather than prompting halfway through the pipeline.

If the recorded display-manager stage no longer owns the system display-manager alias or its rollback transaction is invalid, host artifact preflight stops before confirmation or checkout fetch. The error prints the exact repair command with `display-manager` omitted. Repairing that ledger changes neither the current greeter nor the stored rollback files; after the host state is repaired, `omarchy overlay setup display-manager` re-adopts the stage.

The overlay-dispatch marker is a compatibility contract, not an incidental comment. Before fast-forwarding, `omarchy-update-overlay` reads the upstream blob of `bin/omarchy-update` and requires the literal line `# Desktop-overlay update dispatch is supported.`. An upstream that drops or rewords it stalls enrolled machines at their current revision until a later upstream commit restores the marker, at which point the existing updater proceeds on its next fetch. `test/shell.d/overlay-update-test.sh` asserts the marker is present in the real dispatcher so the contract cannot be broken by an unrelated cleanup.

The maintained overlay branch is append-only from the clients' perspective. Upstream changes are integrated centrally with signed merge commits, the maintained branch is never rebased or force-pushed, and enrolled machines consume only fast-forwards. A locally-ahead checkout remains usable. Tracked modifications, a detached branch, or divergent history must be repaired before system packages change. Untracked files are allowed because they do not alter tracked update code; if an incoming fast-forward collides with one, Git refuses the merge before package reconciliation.

Changed files under `config/` are reported instead of copied because those paths are user-owned after initial setup. The update prints one `omarchy refresh config <relative-path>` command per changed default so the user can inspect and opt into each refresh.

## Path 2: direct `sudo pacman -Syu` attempt

High-level flow:

```text
sudo pacman -Syu
  ├─ pre-transaction guard aborts and tells the user to run omarchy update
  └─ if explicitly bypassed, upgrades omarchy and related packages
  └─ at that user's next login
       ├─ graphical-session.target starts
       ├─ omarchy-migrate-notify.service starts after it
       ├─ omarchy-migrate-notify checks omarchy-migrate --pending
       ├─ if this user has missing migration state, show notification
       └─ click opens terminal: omarchy-migrate
```

Login is deliberately the only trigger. A watcher on the packaged migration
directory cannot distinguish a bypassed `pacman -Syu` from the package
transaction inside a normal `omarchy update`, so it fired notifications for
migrations that `omarchy-migrate` was about to apply in the visible update
terminal. The retired unit was `omarchy-update-user-notify.path`.

Retiring that watcher through a migration cannot come in time for the update
that retires it: pacman writes the migration directory, the watcher fires, and
only then does `omarchy-migrate` reach the migration that stops it. So the
notifier also refuses to run while `omarchy update` holds its
`$XDG_RUNTIME_DIR/omarchy-update.lock`, which covers the stale watcher and any
trigger added later — during an update, every pending migration is by
definition already being applied a step away. It checks again after waiting for
the notification server, since that wait is long enough for an update to start
underneath it.

The notifier reads only its own user's runtime directory, never the `/tmp` path
`omarchy-update` falls back to when `XDG_RUNTIME_DIR` is unset. A shared lock
file belongs to whoever created it first, so honouring it would let one user
silence another user's notification. Missing an update and showing a redundant
toast is the better failure.

Suppression is why `omarchy-update-stay-awake` starts its sleep inhibitor with
the lock descriptor closed. That inhibitor outlives the step that starts it, so
an update killed before cleanup would otherwise leave it holding the flock
indefinitely — blocking later updates and, now that the notifier reads the same
lock, silencing migration notifications at every login.

Fallbacks:

- `omarchy-provision-first-run` enables `omarchy-migrate-notify.service`, which also
  covers users created after install: their per-user migration markers are
  missing, so their first login prompts them to run every shipped migration.
- The package ships `omarchy-update-user-notify.service` as a symlink onto
  `omarchy-migrate-notify.service`. Users set up before the rename hold an
  absolute `graphical-session.target.wants` symlink to the old path, and the
  migration that repoints it only runs for users who run an update — the
  opposite of who the notifier is for. The alias can be dropped once installs
  have run migration `1785095882`.
- The notifier is ordered after `graphical-session.target`, so an action that
  launches through `uwsm-app` cannot block the target that gates UWSM's app
  daemon.
- The notifier waits for a live notification server before sending, because
  `graphical-session.target` can be reached before the shell claims
  `org.freedesktop.Notifications`.
- The notifier is only a prompt. It does not run migrations in the background.
- A session that is already open when another user updates is not re-checked;
  it picks the migrations up at its next login, or whenever that user runs
  `omarchy-migrate` or `omarchy update`.
- Direct pacman updates do not run `omarchy-hook post-update` unless the user
  explicitly runs that hook; without a package-update marker, the only pending
  state we can derive is missing per-user migration markers.

## Shell update indicator

The bar widget `omarchy.system-update` runs:

```bash
omarchy-update-available
```

`omarchy-update-available` uses the same installation detector as the dispatcher and checks only the sources relevant to that type:

- desktop overlays: new upstream commits for the registered checkout only
- product dev links: new upstream commits for the active checkout plus the installed product package
- package-backed products: `omarchy-dev`, when installed, otherwise `omarchy`

The checkout check fetches the configured upstream before comparing it with `HEAD`. Desktop overlays also require the same clean, attached, non-divergent state as the updater. A failed fetch is quiet and falls back to the existing remote-tracking state.

Exit codes:

- `0` — Omarchy updates are available; stdout is the update list.
- `1` — no Omarchy updates are available; stdout says Omarchy is up to date.
- `2` — installation or checkout state is invalid or cannot be classified; the shell leaves the existing indicator unchanged.

The widget runs this check on shell startup and every six hours. Clicking the
update icon launches `omarchy-update` in a floating terminal.

## Channels and versions

Product updates install whatever the active channel points at. `omarchy-channel-set <stable|rc|edge|dev>` switches channels: the three package channels select which pacman repo the mirrorlist points at and swap between the `omarchy` and `omarchy-dev` packages through a guard-allowed pacman run, while `dev` links the product runtime to a Git checkout. Desktop overlays do not have a package channel; they follow the maintained upstream branch configured on their checkout, channel changes are refused before any system mutation, and the product channel submenu is hidden for them. The submenu remains available on a successfully classified product even when a custom mirror makes its current channel `unknown`, so it can be used to return to a supported channel; detector failures still hide it.

There is no version file at runtime. `omarchy-version` derives a product version from `pacman -Q`, reports `dev (<hash>)` for a product dev link or an unregistered checkout during its adoption window, and reports `desktop overlay (<hash>)` for an overlay. `omarchy-version-channel` reports `desktop-overlay` for an overlay, `dev` for an unregistered checkout, and otherwise derives the product package channel from the mirrorlist and `pacman.conf`. These read-only labels validate the installation classification but do not require the current user to own the overlay ledger; ownership remains mandatory for setup, migration, and updates.

## Update-related binaries

This inventory is intentionally opinionated. Some commands are useful as stable
leaf commands; others exist mostly because the old update flow accreted small
scripts.

| Binary | Current purpose | Keep? / Question |
| --- | --- | --- |
| `omarchy-update` | Public user command. Adds transcript logging and locking, then dispatches to the product or desktop-overlay pipeline. | **Keep.** This is the blessed entry point and preserves the product's confirmation, snapshot, and restart behavior. |
| `omarchy-installation-type` | Read-only installation detector used by update, indicator, version, channel, and checkout commands. | **Keep internal/hidden.** It is the single fail-closed dispatcher boundary. |
| `omarchy-update-overlay` | Stage-aware update pipeline for registered desktop overlays. | **Keep internal/hidden.** It owns checkout fast-forward/re-exec and deliberately excludes product-only steps. |
| `omarchy-overlay-setup` | Public staged installer and reconciler for checkout-backed desktops. | **Keep.** Its manifest groups and root-owned ledger are the overlay package source of truth. |
| `omarchy-overlay-migrate` | Public runner for the separate desktop-overlay migration namespace. | **Keep.** Product and overlay migrations must never share markers or assumptions. |
| `omarchy-update-lock` | Hidden command wrapper that holds the per-user update lock while its child runs. | **Keep internal/hidden.** Isolates update concurrency and lock descriptor handling. |
| `omarchy-update-stay-awake` | Hidden helper that starts or stops update-owned sleep and idle inhibition, restoring only the state it changed. | **Keep internal/hidden.** Keeps inhibitor ownership and cleanup together. |
| `omarchy-update-status` | Hidden helper that refreshes or clears the shell update indicator after rechecking available updates. | **Keep internal/hidden.** Keeps shell status synchronization out of the main pipeline. |
| `omarchy-update-confirm` | Gum confirmation copy for `omarchy update`. | **Question.** Could be inlined into `omarchy-update`; separate file only helps keep copy isolated. |
| `omarchy-update-dev` | Fast-forwards the active dev-linked checkout from its configured upstream; no-ops for package-backed installs. | **Keep.** Runs before package updates so a checkout conflict stops the update before system mutation. |
| `omarchy-update-keyring` | Ensures Omarchy keyring and Arch keyring are current before the main transaction. | **Keep, but review.** It uses targeted `pacman -Sy` for keyring bootstrapping; acceptable for this special case but should remain tightly scoped. |
| `omarchy-update-system-pkgs` | Runs `sudo env OMARCHY_UPDATE_PACMAN=1 pacman -Syu --noconfirm` with `--overwrite '/usr/share/omarchy/*'`, capturing stderr to a report file; on failure it execs `omarchy-update-system-pkgs-when-conflicted`. | **Keep for now.** Small leaf command, clear/testable. |
| `omarchy-update-system-pkgs-when-conflicted` | Hidden conflict handler: quarantines unowned conflicting files under `/var/lib/omarchy/replaced`, retries the upgrade once, restores files the upgrade didn't claim, and hands package-vs-package conflicts to an interactive pacman run (never under `-y`). | **Keep internal/hidden.** Keeps conflict recovery out of the happy path. |
| `omarchy-update-pkg-prune` | Trims the pacman cache to two versions per package (`paccache -rk2`) before the snapshot, keeping the offline downgrade path while capping snapshot growth. | **Keep internal/hidden.** |
| `omarchy-update-requires-free-space` | Aborts below 10 GiB free on `/`; on LVM/XFS, also blocks at 80% root thin-pool data or 70% metadata usage and fails closed when pool health is unavailable; `OMARCHY_UPDATE_FORCE=1` bypasses. | **Keep internal/hidden.** |
| `omarchy-migrate` | Public migration command. Waits for pacman, then runs all pending migrations for the current user. Supports `--pending`. | **Keep.** This replaces the discarded `omarchy-update-user-finalize` name and no longer needs `--force`. |
| `omarchy-update-pacman-guard` | ALPM pre-transaction guard that aborts direct `pacman -Syu` style upgrades unless Omarchy set `OMARCHY_UPDATE_PACMAN=1` or the user explicitly set `OMARCHY_ALLOW_DIRECT_PACMAN=1`. | **Keep internal/hidden.** This is what nudges users back to `omarchy update`. |
| `omarchy-migrate-notify` | Internal login-time notification helper. Uses `omarchy-migrate --pending` and shows a notification only when this user has pending migrations. | **Keep internal/hidden.** Clear name now that the public command is `omarchy-migrate`. |
| `omarchy-update-user-notify` | Hidden compatibility wrapper for `omarchy-migrate-notify`. | **Temporary.** Keep only for old callers. |
| `omarchy-update-available` | Update checker for shell widget and post-update refresh. | **Keep.** Could eventually be renamed `omarchy-update-check`, but current name matches widget semantics. |
| `omarchy-update-aur-pkgs` | Updates AUR packages with `yay -Sua` if foreign packages exist and AUR is reachable. | **Question.** Omarchy is package-backed now, but users may still install AUR packages. Keep for now. |
| `omarchy-update-mise` | Runs `MISE_MINIMUM_RELEASE_AGE=0 mise up` for mise-managed tools — the override of mise's release-age cooldown is the point. | **Keep.** Mise-managed tools are intentionally part of the blessed update path. |
| `omarchy-update-orphan-pkgs` | Lists orphans and prompts before removal; noninteractive mode never removes. | **Keep for now.** Safe because it is prompt-only. |
| `omarchy-update-analyze-logs` | Scans `/tmp/omarchy-update.log` for known failure patterns, currently initramfs generation. | **Keep/expand.** Useful safety net; should grow only for high-signal checks. |
| `omarchy-update-restart` | Prompts for reboot after kernel/Hyprland updates, restarts components with `restart-*-required` markers, and always restarts the shell. | **Keep.** Important final step; may eventually include service-restart checks. |
| `omarchy-update-firmware` | Manual firmware update command using fwupd. Not part of the normal update pipeline. | **Keep separate.** Firmware is not a routine system update step. |
| `omarchy-update-time` | Restarts `systemd-timesyncd`. | **Question.** Not really an update command. Consider renaming/moving under system/time maintenance. |

## Closed decisions

1. **Migrations run per-user from the update pipeline**
   - `omarchy update` runs `omarchy-migrate` after pacman finishes.
   - Package-time migration runners do not apply migrations inside pacman.
   - Every user has per-user migration markers, and migrations must be
     idempotent when they repair machine-wide state.

2. **Migration notification naming**
   - The real helper is `omarchy-migrate-notify`, started by
     `omarchy-migrate-notify.service`.
   - `omarchy-update-user-notify` remains only as a hidden compatibility wrapper.

3. **Update pipeline ownership**
   - `omarchy-update` owns installation-type detection, transcript logging, locking, and dispatch. Each installation type owns its explicit pipeline after dispatch.

4. **Mise remains in the product update path**
   - `omarchy-update-mise` intentionally runs for product installations. Desktop overlays do not install or update mise.

5. **Orphan cleanup stays in the product update path for now**
   - It is prompt-only and never removes packages noninteractively. Desktop overlays leave host package cleanup to the user.

6. **Direct pacman user follow-up is based on actual migration state**
   - Direct `sudo pacman -Syu` no longer uses a fake user-update marker.
   - User notifications are shown only when `omarchy-migrate --pending` finds
     missing per-user migration state.

## Remaining concerns

1. **Pacman guard scope**
   - The guard detects direct pacman sysupgrade invocations and allows Omarchy
     commands that set `OMARCHY_UPDATE_PACMAN=1`.
   - We may regret blocking some legitimate package-manager frontends or
     maintenance flows. Keep an eye on what should be allowed versus redirected
     to `omarchy update`.

2. **Pacnew/pacsave handling is still missing**
   - Package-backed Omarchy should warn about or help process `.pacnew` and
     `.pacsave` files after updates.
