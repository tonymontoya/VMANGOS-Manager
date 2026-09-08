# Install-wizard smoke (issue #104)

A real, end-to-end install smoke. It runs the install-wizard stack — the
wizard TUI, the runner (`manager/lib/installer.sh`), `vmangos_setup.sh`, the
marker protocol, and the viewer — against **reality**: the install is
launched by driving `vmangos-manager install` in a pty like a user (gate
button, typed form answers, review confirm), real apt, real MySQL/MariaDB, a
real MangOS build, real MPQ extraction (mmaps generation skipped by default —
see [Runtime expectations](#runtime-expectations)), real systemd services,
real markers, and a real verified retry. It exercises the #104 acceptance scenarios plus
two folded-in additions:

* the **transient-unit name-recreation edge** after a completed run, and
* **re-running the viewer suite for stability** under long runs (the #113
  race is fixed; any failure fails the smoke).

Everything runs inside a throwaway privileged systemd Docker container. It
**never** touches bds (the live realm). The client-data cache is kept on the
host and re-mounted on every run, so re-smokes are cheap.

## Why a privileged systemd container

The install runner launches the install as a transient systemd unit
(`systemd-run --unit=vmangos-install --collect`) and the viewer polls
`systemctl`/`journalctl`. To validate that for real, the container must run
systemd as PID 1. The base image installs systemd; two things are load-bearing
and easy to break (see the `Dockerfile`):

* **No** `VOLUME ["/sys/fs/cgroup"]` — a Docker volume shadows the cgroup
  filesystem with ext4 and systemd dies (exit 255).
* Run with `--privileged --cgroupns=host` so the container sees the host
  cgroup2 hierarchy, which is writable under `--privileged`.

## Prerequisites

* Docker (daemon reachable, no sudo needed in this environment).
* A client-data directory with `base.MPQ` (defaults to `/home/tony/Data`;
  override with `--client-data PATH`).
* Network access (apt, github.com, PyPI).

## Run

```sh
# Full smoke (build image -> container -> manager -> TUI launch -> scenarios
# -> watch to completion -> verify -> teardown). ~30 min on a 10-core
# workstation: MoveMapGen (the ~2.5h mmaps step) is SKIPPED by default —
# use --full-extraction when the extraction/mmaps code itself changes.
tests/smoke/wizard_smoke.sh

# Complete run incl. MoveMapGen (~4.5 h) — for extraction-code changes:
tests/smoke/wizard_smoke.sh --full-extraction

# A single phase (each is independently testable):
tests/smoke/wizard_smoke.sh --phase build-image
tests/smoke/wizard_smoke.sh --phase setup
tests/smoke/wizard_smoke.sh --phase manager
tests/smoke/wizard_smoke.sh --phase tui-launch
tests/smoke/wizard_smoke.sh --phase tui-attach
tests/smoke/wizard_smoke.sh --phase kill-reattach
tests/smoke/wizard_smoke.sh --phase failure-retry
tests/smoke/wizard_smoke.sh --phase watch
tests/smoke/wizard_smoke.sh --phase completion
tests/smoke/wizard_smoke.sh --phase name-recreation
tests/smoke/wizard_smoke.sh --phase flake-watch
tests/smoke/wizard_smoke.sh --phase snapshot
tests/smoke/wizard_smoke.sh --phase resume-install
tests/smoke/wizard_smoke.sh --phase teardown

# Keep the container for inspection (skip teardown):
tests/smoke/wizard_smoke.sh --keep

# Re-smoke from a snapshot image instead of a clean run (~10 min; below):
tests/smoke/wizard_smoke.sh --from-snapshot vmangos-smoke-snap-data
```

Tear down and prepare for a fresh run (keeps the client-data cache):

```sh
tests/smoke/reset.sh
```

## How the TUI is driven

The wizard is not bypassed: `tui-launch` runs `vmangos-manager install`
inside a detached tmux session (a real pty with a fixed 140x60 size), feeds
keystrokes with `tmux send-keys`, and asserts on the rendered screen text
(`tmux capture-pane` gives plain text, no ANSI noise). The keystroke script:
Enter (gate continue) → Tab, type the client-data path, Tab x11, Enter
(review) → Tab, Enter (confirm & start) → Enter (follow the install — the
viewer attaches) → q (detach). Every screen is captured to
`/tmp/vmangos-smoke-evidence/` **on the host** (override with
`SMOKE_EVIDENCE_DIR`) and printed into the smoke log. The wizard itself
writes the secrets file and starts the unit — the smoke never pre-writes
secrets or calls the runner directly on the launch path.

## What each scenario checks

| Scenario | Assertion |
|---|---|
| `tui-launch` | Gate → form → review → launch → follow (viewer attaches) → q (detach) driven in a pty; the TUI writes the secrets (right values, mode 600) and starts the unit (`ActiveState=active`); the app exits 0 after detaching; screen evidence captured. |
| `tui-attach` | Re-running `install` while the unit runs attaches the live viewer (checklist renders); `q` detaches, the app exits 0, and the unit **keeps running**. |
| `kill-reattach` | Kill the viewer's journal session; the unit **keeps running**; re-attach works. |
| `failure-retry` | Stop the unit after the first phase checkpoint; the runner's retry path (`installer_unit_stop` + `installer_unit_start` — what the FailureScreen's Retry runs) restarts it. Resume is **verified three ways**: the retried invocation logs `Resuming from checkpoint: <captured>`, no completed phase re-ran (prerequisites never starts again), and the checkpoint then advances past the captured one. |
| `watch` | Markers stream until the terminal `phase=install event=done` marker. |
| `completion` | Terminal marker present; `auth` + `world` services active; the `realmlist` row is **queried from the database inside the container** and its address/port must match the marker's `server_ip`/`world_port` (the marker alone is the installer grading its own homework). When this run executed the extraction phase, the mmaps skip (default) or full extraction (`--full-extraction`) is verified against the journal markers. |
| `name-recreation` | After a completed run, the runner re-creates the unit name (`installer_unit_start`) and the unit runs our installer; it is stopped again via `installer_unit_stop` (a real re-install goes through the wizard's gate — this exercises the `--collect` name edge). |
| `flake-watch` | The viewer async suite is re-run N times (`SMOKE_FLAKE_RUNS`, default 5) as a stability gate. Any failure fails the smoke and its output is captured — the #113 unit-state race is fixed (`first_seconds` 15s window exceeds the checker's 5s query timeout), so no failure is tolerated. |
| `snapshot` | Once the container's install checkpoint passes `SMOKE_SNAPSHOT_AFTER` (default `DATA_DONE`), the container is `docker commit`ed into a tagged snapshot image. Works in parallel with a running smoke or against a kept container whose checkpoint already satisfies the target. |
| `resume-install` | Starts the install from the checkpoint embedded in a snapshot image via the runner (the same path Retry takes); verifies a fresh `Resuming from checkpoint: <cp>` journal line and freezes the embedded phases' start-marker counts for `completion` to check. |

## Runtime expectations

A default clean run is **~30 minutes** on a 10-core workstation. The
breakdown (from recorded runs): image build + container + manager + TUI
launch ~3 min; prerequisites ~5 min; database (mysql-server install) ~1
min; source ~1 min; MangOS build ~5 min; DBC/map + vmap extraction ~2 min;
db import ~1-2 min; service bring-up ~1 min; scenarios ~10 min.

**MoveMapGen is skipped by default.** It is single-threaded and generates
mmaps for every map that has vmaps — the two large continent maps (Elwynn
Forest, Dustwallow Marsh) each take well over an hour, ~2.5 h total. The
extraction path (extractors, vmap assembly, mmaps) is verified by real
full runs, and the server runs fine without mmaps (NPC pathfinding
disabled), so the smoke skips it via the `VMANGOS_SKIP_MMAPS=1` seam: the
smoke exports it, the TUI's inherited environment carries it, the runner
forwards it into the unit, and `vmangos_setup.sh` skips the step with a
warn marker (`mmaps skipped by request`). `completion` asserts the marker
whenever the run executed the extraction phase — a broken seam fails fast
instead of silently burning hours.

Run the complete extraction **only** when the extraction/mmaps code itself
changes (`vmangos_setup.sh` extraction phase, the extractor build, or
MoveMapGen wiring):

```sh
tests/smoke/wizard_smoke.sh --full-extraction   # ~4.5 h
```

The `watch` phase has a **6 h** ceiling by default (`SMOKE_WATCH_TIMEOUT` /
`SMOKE_INSTALL_TIMEOUT` to override). `failure-retry` waits for the first
phase checkpoint before forcing its failure (prerequisites' real apt, ~5 min;
`SMOKE_PREREQS_TIMEOUT`, default 25 min, and `SMOKE_ADVANCE_TIMEOUT`,
default 15 min, bound the two waits).

## Snapshots: cheap re-smokes (#116)

Even a ~30 min default run re-pays apt, the database setup, the build, and
the extraction. Changes to the viewer, the completion checks, or the
services never need to re-exercise those — so the smoke can `docker commit`
the container at a checkpoint and re-run from the committed image instead
of the base image:

```sh
# Terminal 1: any run (--keep so the container survives for the re-smoke):
tests/smoke/wizard_smoke.sh --keep

# Terminal 2, while it runs: wait for the checkpoint, commit the image.
# Default checkpoint: DATA_DONE (everything through extraction).
tests/smoke/wizard_smoke.sh --phase snapshot
# -> vmangos-smoke-snap-data (the tag derives from the checkpoint)

# Other checkpoints (e.g. skip only prerequisites+database+source):
SMOKE_SNAPSHOT_AFTER=SOURCE_DONE tests/smoke/wizard_smoke.sh --phase snapshot
# -> vmangos-smoke-snap-source
```

`--phase snapshot` also works against a `--keep`'d container after the
run ends, as long as the checkpoint file still satisfies the target — a
**completed** install clears its checkpoints, so a finished container can
no longer be snapshotted.

A snapshot image embeds everything the finished phases produced: the
install root (checkpoint file, build tree, extracted DBC/maps/vmaps/mmaps),
the databases, the installed manager, and the secrets the TUI wrote. A
re-smoke starts a fresh container from it and resumes the install from the
embedded checkpoint:

```sh
tests/smoke/wizard_smoke.sh --from-snapshot vmangos-smoke-snap-data
```

The re-smoke flow replaces `build-image`/`tui-launch` with `resume-install`
(starts the install from the embedded checkpoint through the runner — the
same path Retry takes; the wizard's gate is deliberately not clean here)
and verifies the resume itself: the journal must show a fresh
`Resuming from checkpoint: <cp>`, and at `completion` the start-marker
counts of every phase embedded in the snapshot are compared against
baselines frozen at resume time — build and extraction (and everything
before them) must never start again. `failure-retry` runs right after the
resume (inside the short db-import window), then `tui-attach`,
`kill-reattach`, `watch`, `completion`, `name-recreation`, and
`flake-watch` all run unchanged on the resumed install.

Expected cost by starting checkpoint (10-core workstation):

| Snapshot image | Default for | Re-smoke skips | Re-smoke cost |
|---|---|---|---|
| `vmangos-smoke-snap-data` | `DATA_DONE` | prerequisites + database + source + build + config + **extraction** | **~10 min** (setup+manager ~3 min, db-import ~1-2 min, services ~1 min, scenarios) |
| `vmangos-smoke-snap-source` | `SOURCE_DONE` | prerequisites + database + source | ~15 min (build + extraction still run; mmaps skipped by default) |

A snapshot mirrors the run that created it: one created from a default
(skip-mmaps) run embeds an install root without mmaps — exactly what its
re-smokes would produce anyway, and everything the completion checks need.
Create it with `--full-extraction` if you need real mmaps embedded.

Notes:

* Committed services are captured as-is — like a power cut. MySQL recovers
  its journals when the re-smoked container boots; the transient install
  unit never survives (its state lives in `/run`, which is not committed).
* The journal **does** survive inside the snapshot (`/var/log/journal`), so
  marker counts accumulate across re-smokes — the baselines are frozen at
  resume time, never assumed zero.
* Teardown and `reset.sh` never delete snapshot images. Remove them
  explicitly (`docker rmi vmangos-smoke-snap-data`) or all at once with
  `reset.sh --snapshots`.

The client-data cache (`/home/tony/Data`, ~5.2 GB of MPQs) is mounted read-only
and kept across runs, so the extraction/db-import phases are reproducible
without re-downloading.

## Findings

* **Extraction on a read-only client-data mount (fixed, this branch):**
  `mapextractor` resolves every archive through a `Data/` entry — it opens
  `<root>/Data/<file>.MPQ`. A bare top-level MPQ directory (like a mounted
  client-data folder) needs a `Data -> .` self-symlink to satisfy that layout;
  a working install ships exactly that. `prepare_extraction_root` used to
  return early whenever the service user could read the MPQs directly, which
  skipped the symlink entirely — fine on a writable client dir, but on a
  read-only mount the self-symlink can never be created and the extractor
  fails with `Invalid Map.dbc file format!` / `Extracted 0 DBC files`. The
  function now guarantees a `Data/`-resolvable root, cheapest first: use the
  client dir if it already exposes `Data/`; add the self-symlink in place if
  the dir is writable; otherwise stage a **symlink farm** in
  `$INSTALLROOT/client-data` (per-MPQ symlinks + `Interface` + `Data -> .`),
  reusing a valid staging root across resumes. A full copy remains the last
  resort when the client data is not readable by the service user at all.
  Verified by running the real `mapextractor` against a `:ro` mount
  (158 DBCs + 2429 maps extracted).
* **Database server: fresh-host install, running-server adoption (this
  branch):** the installer provisions `mysql-server` on a host with no SQL
  server, and adopts an already-running server — but only when it can
  actually administer it (`mysql -e "SELECT 1"` as root via the local
  socket, the exact connection every later statement uses). A
  running-but-unreachable server is refused **at adoption time** with a
  specific error marker; the first version of this change silently adopted
  it and failed later at `FLUSH PRIVILEGES` with a misleading hint. Covered
  by mocked tests for all paths (adopt / install / refused, with and without
  a pre-existing client).
* **Regression fixed (this branch):** the prerequisites phase requested both
  `libmariadb-dev` and `default-libmysqlclient-dev`. On current Ubuntu those
  conflict in apt (`libmariadb-dev` Conflicts `libmysqlclient-dev`, which
  `default-libmysqlclient-dev` Depends on), so the whole prerequisite install
  failed to resolve. Fixed in `vmangos_setup.sh` by requesting
  `default-libmysqlclient-dev` alone (the virtual package that resolves to
  the system MySQL client library, which the MangOS CMake `FindMySQL` module
  accepts). The smoke caught this on first run; the prerequisites phase now
  passes.
* **`unzip` missing from prerequisites (fixed, this branch):** the world-DB
  import downloads a zipped dump; without `unzip` it fell through to a bogus
  legacy SQL file (`ERROR 1146 ... Table 'world.migrations' doesn't exist`)
  and failed with a confusing db-import error marker. Added to the package
  list.
* **Interrupted vmap extraction poisoned the resume (fixed, this branch):**
  the verified failure-retry exposed it — stopping the unit mid-vmap
  extraction left a partial `Buildings/` dir, and `vmapextractor` refuses
  to run into a polluted directory, so the resumed install silently
  skipped vmaps AND mmaps (log warnings only, no error marker) and still
  marked `DATA_DONE`: a degraded server posing as a complete one. The
  extraction step now clears a partial `Buildings/` before re-running
  (MoveMapGen already resumes tile-by-tile on its own). Covered by a
  mocked installer test.
* **Viewer read the journal in the wrong format (fixed, this branch):**
  the attach phase showed the checkpoint fallback forever — `parse_marker`
  matches markers at the start of a line, but `journalctl`'s default
  format prefixes every line with a timestamp/host/proc header, so against
  a real journal the viewer folded zero markers and would have shown the
  EndedScreen even on a successful install. The journal tail now runs with
  `-o cat` (message-only). The stubbed journalctl in the tests emits
  message-only lines, which is why the pilot tests never saw it.
* **Wizard secrets file was not shell-safe (fixed, this branch):** the
  launch screen's first real drive failed with `line 8: a: unbound
  variable` — generated passwords draw from a charset including `$`, and
  the file's consumers `source` it, so `$$`/`$a` inside a double-quoted
  value expanded (or tripped `set -u`). `render_setup_conf` now escapes
  `\ $ " and backtick; `parse_secrets_file` reverses it. Round-trip tests
  run hostile values through both the parser and a real `bash -c source`.
  `auto_install.sh` has the same latent quirk in its writer; it is the
  deprecated path, so it is noted on #104 rather than changed.
* **Generated passwords could not live in the server config (fixed, this
  branch):** the first fully TUI-launched run reached the services phase and
  crash-looped — `realmd` reported `Incorrectly formatted database connection
  string` because the generated password contained `#`, and mangos's Config
  parser (`src/shared/Config/Config.cpp`) ends a value at `#`,
  truncating `LoginDatabaseInfo` mid-password. The wizard's password charset
  now excludes every character a consumer cannot carry (`#` config comment,
  `;` connection-string separator, `"` value quoting, `'` SQL grants,
  `\` escapes). `auto_install.sh`'s generator has the same latent quirk
  (deprecated path, noted on #104).
* **`--collect` + marker-less failure (documented):** because the runner uses
  `systemd-run --collect`, a *failed* unit is unregistered and immediately
  reports `ActiveState=inactive` (not `failed`). The viewer therefore detects
  a failure via the `event=error` marker (which works), not via
  `ActiveState=failed` (which is unobservable under `--collect`). An *unmarked*
  `set -e` death would fall through to the EndedScreen rather than the
  FailureScreen — the gap tracked by #111 is now **closed** (PR #114 guards
  the remaining `set -e` death paths with fail markers), and the viewer's
  unit-state checker catches marker-less deaths regardless.
* **Database failures are no longer silent (hardened, PR #114):** the
  database phase's `CREATE DATABASE` / `CREATE USER` / `GRANT` statements are
  best-effort by design, but a swallowed failure now emits a **warn marker**
  (`phase=database event=warn`) instead of passing unnoticed —
  `phase=database event=done` never asserts an unverified step, and the
  import phase fails loudly if a database or grant that mattered is still
  missing. `FLUSH PRIVILEGES` failing is a hard phase failure with its own
  error marker.
* **Viewer-test race (fixed by #115):** the viewer's unit-state checker
  thread raced the UI tick inside two tests
  (`test_viewer_detects_unit_failure_without_markers` and its sibling
  `..._unit_ended_without_completion`) — tracked as #113. The stub's active
  window (15s) now exceeds the checker's 5s query timeout, a timed-out poll
  no longer consumes the "active" observation, and the wait predicates gate
  on the rendered screen text (the blank window between `push_screen` and
  `compose` was the flake). Verified with 6/6 consecutive pair runs plus the
  full suite; the smoke's flake-watch no longer tolerates it.
* **PATH-installed manager needs the setup script beside the install root
  (arranged, this branch):** the wizard resolves `vmangos_setup.sh` one
  directory above the manager prefix (the layout of a repo checkout), so a
  manager installed to a prefix and driven via PATH needs
  `<parent-of-prefix>/vmangos_setup.sh` to exist. The smoke pre-installs the
  manager to `/opt/vmangos-manager` — deliberately **outside** the install
  root, because the gate treats an existing `/opt/mangos` as an existing
  installation — and links the mounted repo's script to
  `/opt/vmangos_setup.sh`; a fresh host running from its checkout already
  has this layout.
