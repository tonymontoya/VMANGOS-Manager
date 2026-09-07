#!/usr/bin/env bash
#
# wizard_smoke.sh — real end-to-end install smoke in a privileged systemd
# Docker container (issue #104).
#
# Validates the install-wizard stack (wizard TUI + runner + vmangos_setup.sh +
# markers + viewer) against reality: the install is STARTED through
# `vmangos-manager install` driven like a user (a tmux-fed pty: gate button,
# form keystrokes, review confirm), then followed live by re-running
# `install` (the attach path). Real apt, real MySQL, real build, real MPQ
# extraction, real systemd services, real markers, real retry. It exercises
# the claims from #104 plus two folded-in additions:
#   * the transient-unit name-recreation edge after a completed run, and
#   * re-running the viewer suite for stability under long runs (the #113
#     race is fixed; any failure fails the smoke).
#
# The smoke runs entirely inside a throwaway container; it NEVER touches bds.
# The client-data cache is kept on the host and re-mounted on every run.
#
# Phases (run in order by default; --phase runs one):
#   build-image     build the systemd base image
#   setup           create the container + wait for systemd
#   manager         install the manager + bootstrap the venv
#   tui-launch      drive `vmangos-manager install` in a tmux pty: gate ->
#                   form (typed answers) -> review -> confirm -> follow the
#                   install (viewer attaches) -> q detaches; the TUI writes
#                   the secrets and starts the unit (screen evidence kept)
#   tui-attach      re-run `install` while the unit runs: the viewer attaches;
#                   detach with q; the unit keeps running
#   kill-reattach   kill the viewer session, verify the unit keeps running
#   failure-retry   force a failure, drive the runner's retry, VERIFY resume:
#                   same checkpoint advancing, no completed phase re-ran
#   watch            stream markers until the install ends
#   completion      verify auth/world active + completion marker + realmlist
#                   row verified against the database (not just the marker)
#   name-recreation re-create the unit name through the runner after a
#                   completed run, then stop it again
#   flake-watch     re-run the viewer async suite N times; any failure
#                   fails the smoke (the #113 race is fixed)
#   snapshot        docker-commit the container once its checkpoint passes
#                   SMOKE_SNAPSHOT_AFTER (default DATA_DONE) into a tagged
#                   snapshot image for cheap re-smokes (#116)
#   resume-install  start the install from the checkpoint embedded in a
#                   snapshot image via the runner; verifies the resume and
#                   freezes phase-start baselines for completion to check
#   teardown        remove the container (keep the client-data cache)
#
# Iterating: a full clean install can exceed 4h. Instead of paying that on
# every re-smoke, `--phase snapshot` commits the container at a checkpoint
# (default DATA_DONE: everything through extraction) and `--from-snapshot
# TAG` re-runs the late phases (~10 min) from that image; see the README.
#
# Usage:
#   tests/smoke/wizard_smoke.sh [--phase NAME] [--keep] [--client-data PATH]
#                               [--container NAME] [--image NAME] [--repo PATH]
#                               [--from-snapshot [TAG]]
#
# Exit status: 0 when the requested phase(s) pass, non-zero otherwise.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config (env-overridable defaults, then flags)
# ---------------------------------------------------------------------------
SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SMOKE_DIR/../.." && pwd)"
CONTAINER_NAME="${SMOKE_CONTAINER_NAME:-vmangos-wizard-smoke}"
IMAGE_NAME="${SMOKE_IMAGE_NAME:-vmangos-smoke-base}"
CLIENT_DATA="${SMOKE_CLIENT_DATA:-/home/tony/Data}"
# The manager is pre-installed OUTSIDE the install root: the wizard's gate
# treats an existing $INSTALL_ROOT directory as an existing installation, and
# the real install later provisions the manager under it itself. The wizard
# resolves the setup script one directory above the manager prefix (the
# layout of a repo checkout); the manager phase links it there.
MANAGER_PREFIX="/opt/vmangos-manager"
MANAGER_BIN="$MANAGER_PREFIX/bin"
SECRETS_FILE="/root/.vmangos-secrets/setup.conf"
SETUP_SCRIPT="/opt/vmangos_setup.sh"
INSTALL_ROOT="/opt/mangos"
CHECKPOINT_FILE="$INSTALL_ROOT/.install-checkpoints/checkpoint"
# Where the client data lands inside the container (read-only mount).
CLIENT_DATA_CONTAINER="/mnt/client-data"
# Where TUI screen evidence is kept on the HOST (survives teardown).
EVIDENCE_DIR="${SMOKE_EVIDENCE_DIR:-/tmp/vmangos-smoke-evidence}"

PHASE="all"
KEEP=0
TIMEOUT_SYSTEMD="${SMOKE_SYSTEMD_TIMEOUT:-120}"
# 6h ceiling for a full clean build: MoveMapGen alone takes ~2.5h on a 10-core
# workstation (single-threaded), so the whole install can exceed 4h.
TIMEOUT_INSTALL="${SMOKE_INSTALL_TIMEOUT:-21600}"
# How long the TUI phases wait for a screen to appear / the app to exit.
TIMEOUT_TUI="${SMOKE_TUI_TIMEOUT:-180}"
# failure-retry: how long to wait for the first phase checkpoint (prerequisites
# runs real apt, ~5 min) and for the resumed run to advance past it.
TIMEOUT_PREREQS="${SMOKE_PREREQS_TIMEOUT:-1500}"
TIMEOUT_ADVANCE="${SMOKE_ADVANCE_TIMEOUT:-900}"
# Snapshots (#116): commit the container at a checkpoint, then re-smoke from
# the committed image. SMOKE_SNAPSHOT_AFTER picks the checkpoint to wait for:
# SOURCE_DONE makes re-smokes skip prerequisites+database+source; DATA_DONE
# (the default) additionally skips build+config+extraction — the ~4h part.
SNAPSHOT_AFTER="${SMOKE_SNAPSHOT_AFTER:-DATA_DONE}"
SNAPSHOT_TAG="${SMOKE_SNAPSHOT_TAG:-}"
# Start the container from a snapshot image instead of the base image
# (--from-snapshot [TAG], or SMOKE_FROM_SNAPSHOT).
FROM_SNAPSHOT="${SMOKE_FROM_SNAPSHOT:-}"

# ---------------------------------------------------------------------------
# Logging + helpers
# ---------------------------------------------------------------------------
log()  { printf '[smoke] %s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
pass() { log "PASS: $*"; }
fail() { log "FAIL: $*"; exit 1; }

# docker exec with the manager bin prepended to PATH (the manager resolves its
# lib via SCRIPT_DIR/../lib, so it must be invoked by its real path, not a
# symlink).
docker_exec() {
    docker exec -e "PATH=$MANAGER_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "$CONTAINER_NAME" bash -c "$*"
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
    docker info >/dev/null 2>&1 || die "cannot reach the docker daemon"
}

require_client_data() {
    [[ -d "$CLIENT_DATA" ]] || die "client data not found at $CLIENT_DATA"
    [[ -f "$CLIENT_DATA/base.MPQ" ]] || die "client data at $CLIENT_DATA has no base.MPQ"
}

# ---------------------------------------------------------------------------
# Unit / journal / checkpoint state
# ---------------------------------------------------------------------------

# The unit's ActiveState (or 'unknown').
unit_state() {
    docker_exec "systemctl show -p ActiveState vmangos-install.service --value" 2>/dev/null || echo unknown
}

unit_running() {
    case "$(unit_state)" in
        active|activating) return 0 ;;
        *) return 1 ;;
    esac
}

require_unit_running() {
    unit_running || fail "$1: unit not running (ActiveState=$(unit_state))"
}

# The most recent marker line from the unit's journal (empty if none).
latest_marker() {
    docker_exec "journalctl -u vmangos-install --no-pager 2>/dev/null" \
        | grep -F '@@VMANGOS v1' | tail -1 || true
}

# Number of lines in the unit's journal matching the fixed string.
journal_count() {
    docker_exec "journalctl -u vmangos-install --no-pager 2>/dev/null" \
        | grep -cF -- "$1" || true
}

# The installer's current checkpoint (empty when there is none).
checkpoint_read() {
    docker_exec "cat '$CHECKPOINT_FILE' 2>/dev/null" | tr -d '[:space:]' || true
}

# Position in the checkpoint chain (START=0 … SERVICES_DONE=8, -1 unknown).
checkpoint_rank() {
    case "$1" in
        START)           echo 0 ;;
        PREREQS_DONE)    echo 1 ;;
        DATABASE_DONE)   echo 2 ;;
        SOURCE_DONE)     echo 3 ;;
        BUILD_DONE)      echo 4 ;;
        CONFIG_DONE)     echo 5 ;;
        DATA_DONE)       echo 6 ;;
        DB_IMPORT_DONE)  echo 7 ;;
        SERVICES_DONE)   echo 8 ;;
        *)               echo -1 ;;
    esac
}

# Rank of the *_DONE checkpoint a phase writes when it completes
# (prerequisites -> PREREQS_DONE, ..., extraction -> DATA_DONE).
phase_done_rank() {
    case "$1" in
        prerequisites) echo 1 ;;
        database)      echo 2 ;;
        source)        echo 3 ;;
        build)         echo 4 ;;
        config)        echo 5 ;;
        extraction)    echo 6 ;;
        *)             echo -1 ;;
    esac
}

# Default snapshot image tag for a checkpoint (SOURCE_DONE ->
# vmangos-smoke-snap-source, DATA_DONE -> vmangos-smoke-snap-data). The
# snap- family is distinct from the vmangos-smoke-base image so reset.sh
# can tell them apart.
snapshot_default_tag() { # snapshot_default_tag <CHECKPOINT>
    local c="${1,,}"
    c="${c%_done}"
    printf 'vmangos-smoke-snap-%s\n' "${c//_/-}"
}

# Poll until the checkpoint exists and is past the given chain position.
wait_checkpoint_past() {
    local rank="$1" timeout="$2"
    local deadline=$(( $(date +%s) + timeout )) cp
    while (( $(date +%s) < deadline )); do
        cp="$(checkpoint_read)"
        if [[ -n "$cp" ]] && (( $(checkpoint_rank "$cp") > rank )); then
            printf '%s\n' "$cp"
            return 0
        fi
        sleep 5
    done
    return 1
}

# ---------------------------------------------------------------------------
# TUI driving (tmux inside the container: deterministic size, plain-text
# screen capture, keystroke feeding)
# ---------------------------------------------------------------------------

tux() {
    docker exec -e TMUX_TMPDIR=/tmp "$CONTAINER_NAME" tmux "$@"
}

# Start `vmangos-manager install` in a detached tmux session (a real pty).
# The app's exit code lands in the given file when the session ends.
tui_start() { # tui_start <session> <exit-file>
    tux new-session -d -x 140 -y 60 -s "$1" \
        "env TERM=xterm-256color HOME=/root PATH=$MANAGER_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin vmangos-manager install; printf '%s' \"\$?\" > '$2'"
}

# Wait until the session's current screen contains the fixed string.
wait_pane_text() { # wait_pane_text <session> <text> [timeout]
    local session="$1" text="$2" timeout="${3:-$TIMEOUT_TUI}"
    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if tux capture-pane -t "$session" -p 2>/dev/null | grep -qF -- "$text"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# Save the session's current screen as evidence (host side) and show it.
capture_screen() { # capture_screen <session> <name>
    local session="$1"
    mkdir -p "$EVIDENCE_DIR"
    tux capture-pane -t "$session" -p 2>/dev/null > "$EVIDENCE_DIR/$2.txt" || true
    log "--- screen evidence: $2 (also at $EVIDENCE_DIR/$2.txt) ---"
    grep -v '^[[:space:]]*$' "$EVIDENCE_DIR/$2.txt" >&2 || true
    log "--- end: $2 ---"
}

tui_dump_and_fail() { # tui_dump_and_fail <session> <message>
    capture_screen "$1" "FAIL-$(date +%H%M%S)"
    fail "$2"
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

phase_build_image() {
    log "building $IMAGE_NAME from $SMOKE_DIR/Dockerfile"
    docker build -q -t "$IMAGE_NAME" -f "$SMOKE_DIR/Dockerfile" "$SMOKE_DIR" >/dev/null
    pass "image $IMAGE_NAME built"
}

phase_setup() {
    require_docker
    require_client_data
    local image="$IMAGE_NAME"
    if [[ -n "$FROM_SNAPSHOT" ]]; then
        docker image inspect "$FROM_SNAPSHOT" >/dev/null 2>&1 \
            || die "setup: snapshot image $FROM_SNAPSHOT not found (create one with --phase snapshot)"
        image="$FROM_SNAPSHOT"
    fi
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    log "starting container $CONTAINER_NAME (privileged, cgroupns=host) from $image"
    docker run -d \
        --privileged \
        --cgroupns=host \
        --name "$CONTAINER_NAME" \
        -v "$REPO_ROOT":/src:ro \
        -v "$CLIENT_DATA":/mnt/client-data:ro \
        "$image" >/dev/null
    wait_for_systemd
    if [[ -n "$FROM_SNAPSHOT" ]]; then
        # A usable snapshot embeds an in-progress install: its checkpoint
        # and the secrets the TUI wrote when it started the original run.
        local cp
        cp="$(checkpoint_read)"
        [[ -n "$cp" ]] \
            || fail "setup: $FROM_SNAPSHOT has no install checkpoint (committed before any phase finished?)"
        docker_exec "test -f '$SECRETS_FILE'" >/dev/null 2>&1 \
            || fail "setup: $FROM_SNAPSHOT has no secrets file at $SECRETS_FILE"
        log "setup: snapshot state OK — checkpoint=$cp, secrets present"
    fi
    pass "container up, systemd is PID 1"
}

wait_for_systemd() {
    local deadline=$(( $(date +%s) + TIMEOUT_SYSTEMD ))
    local state
    while (( $(date +%s) < deadline )); do
        state="$(docker exec "$CONTAINER_NAME" systemctl is-system-running 2>/dev/null || true)"
        case "$state" in
            running|degraded|stopped)
                log "systemd state: $state"
                return 0
                ;;
        esac
        sleep 2
    done
    docker logs --tail 40 "$CONTAINER_NAME" >&2 2>/dev/null || true
    die "systemd did not become ready within ${TIMEOUT_SYSTEMD}s"
}

phase_manager() {
    log "installing the manager into $MANAGER_PREFIX (outside the install root)"
    docker exec "$CONTAINER_NAME" bash -c "make -C /src/manager install PREFIX=$MANAGER_PREFIX"
    # The wizard resolves the setup script one directory above the manager
    # prefix (the layout of a repo checkout). Link the mounted repo's script
    # there so a PATH-installed vmangos-manager finds it, as on a fresh host
    # that runs from its checkout.
    docker_exec "ln -sfn /src/vmangos_setup.sh '$SETUP_SCRIPT'"
    # Make `vmangos-manager` reachable on PATH for login shells.
    docker exec "$CONTAINER_NAME" bash -c "printf 'export PATH=%s:\$PATH\n' '$MANAGER_BIN' > /etc/profile.d/vmangos-manager.sh"
    # Bootstrap the wizard venv (Textual) the same way a fresh host would.
    docker_exec "vmangos-manager install --bootstrap"
    docker_exec "command -v vmangos-manager" >/dev/null || fail "vmangos-manager not on PATH"
    pass "manager installed + setup script linked + venv bootstrapped"
}

# ---------------------------------------------------------------------------
# TUI phases — the wizard driven like a user
# ---------------------------------------------------------------------------

# Drive the full wizard flow in a pty: gate -> form -> review -> confirm.
# The TUI (not the smoke) writes the secrets file and starts the install unit.
phase_tui_launch() {
    if unit_running; then
        fail "tui-launch precondition: an install unit is already running"
    fi
    # A previous attempt may have left a stale wizard session behind.
    tux kill-session -t wizard 2>/dev/null || true
    docker_exec "rm -f /root/tui-launch.exit /root/tui-attach.exit" >/dev/null 2>&1 || true
    mkdir -p "$EVIDENCE_DIR"

    log "starting the wizard TUI in a tmux pty (no secrets file, clean gate)"
    tui_start wizard /root/tui-launch.exit

    wait_pane_text wizard "Install Wizard" \
        || tui_dump_and_fail wizard "the wizard gate screen never appeared"
    capture_screen wizard 01-gate

    log "gate: Continue to install form"
    tux send-keys -t wizard Enter
    wait_pane_text wizard "Install Form" \
        || tui_dump_and_fail wizard "the install form never appeared"
    capture_screen wizard 02-form

    # Fill the form like the recorded answers: install root and DB fields keep
    # their defaults; the client-data path is typed; the password is the
    # generated default. Tab order: after client_data, 8 inputs + Generate +
    # Back precede the Review button.
    log "form: typing client data path $CLIENT_DATA_CONTAINER, defaults elsewhere"
    tux send-keys -t wizard Tab
    sleep 1
    tux send-keys -t wizard -l "$CLIENT_DATA_CONTAINER"
    sleep 1
    local i
    for i in $(seq 1 11); do
        tux send-keys -t wizard Tab
        sleep 0.3
    done
    capture_screen wizard 03-form-filled
    tux send-keys -t wizard Enter
    wait_pane_text wizard "Review" \
        || tui_dump_and_fail wizard "the review screen never appeared (form validation failed?)"
    capture_screen wizard 04-review

    log "review: Confirm & Start Install"
    tux send-keys -t wizard Tab
    sleep 1
    tux send-keys -t wizard Enter
    wait_pane_text wizard "vmangos-install" \
        || tui_dump_and_fail wizard "the launch screen never reported the unit"
    capture_screen wizard 05-launched

    # The newly mounted "Follow the install" button takes focus: Enter
    # follows straight into the live viewer (the launch-flow attach), and q
    # detaches — both the paths a real user takes from this screen.
    log "launch: Follow the install (viewer attaches)"
    tux send-keys -t wizard Enter
    wait_pane_text wizard "Install Progress" \
        || tui_dump_and_fail wizard "the viewer never attached after Follow"
    sleep 10
    capture_screen wizard 06-follow-viewer
    log "detaching the viewer (q)"
    tux send-keys -t wizard q
    wait_session_end wizard \
        || tui_dump_and_fail wizard "the wizard TUI did not exit after detach"
    local exit_code
    exit_code="$(docker_exec "cat /root/tui-launch.exit 2>/dev/null" || echo x)"
    [[ "$exit_code" == "0" ]] \
        || fail "wizard TUI exited with code $exit_code (expected 0)"

    # The TUI must have written the secrets itself (the smoke never did).
    docker_exec "test -f '$SECRETS_FILE'" >/dev/null 2>&1 \
        || fail "the wizard did not write $SECRETS_FILE"
    docker_exec "grep -q 'INSTALLROOT=\"$INSTALL_ROOT\"' '$SECRETS_FILE'" >/dev/null 2>&1 \
        || fail "the wizard-written secrets lack INSTALLROOT=$INSTALL_ROOT"
    docker_exec "grep -q 'CLIENTDATA=\"$CLIENT_DATA_CONTAINER\"' '$SECRETS_FILE'" >/dev/null 2>&1 \
        || fail "the wizard-written secrets lack CLIENTDATA=$CLIENT_DATA_CONTAINER (was the form answer lost?)"
    local secrets_mode
    secrets_mode="$(docker_exec "stat -c %a '$SECRETS_FILE'" 2>/dev/null || echo none)"
    [[ "$secrets_mode" == "600" ]] \
        || fail "secrets file mode is $secrets_mode (expected 600)"

    # The unit the TUI started must actually be running.
    local deadline=$(( $(date +%s) + 60 ))
    until unit_running; do
        (( $(date +%s) < deadline )) || fail "install unit not running after the TUI launch (ActiveState=$(unit_state))"
        sleep 3
    done
    log "unit ActiveState after TUI launch: $(unit_state)"
    pass "tui-launch: gate -> form -> review -> launch driven in a pty; TUI wrote the secrets and started the unit"
}

# Re-run `vmangos-manager install` while the unit runs: the launch path
# detects it and attaches the live viewer. Detach with q; the unit must keep
# running (detaching never stops the install).
phase_tui_attach() {
    require_unit_running "tui-attach"
    # A previous attempt may have left a stale attach session behind.
    tux kill-session -t attach 2>/dev/null || true
    docker_exec "rm -f /root/tui-attach.exit" >/dev/null 2>&1 || true
    log "re-running 'vmangos-manager install' in a pty (attach path)"
    tui_start attach /root/tui-attach.exit

    wait_pane_text attach "Install Progress" \
        || tui_dump_and_fail attach "the viewer never attached"
    # Give the journal tail a moment to render the checklist/log.
    sleep 15
    capture_screen attach 07-reattach-viewer
    # Progress rendering is either the marker checklist (a phase label) or,
    # when the last 200 journal lines predate the newest marker (a long
    # marker-less apt stretch), the checkpoint fallback line — both honest.
    if ! grep -qE "Prerequisites|Install starting" "$EVIDENCE_DIR/07-reattach-viewer.txt"; then
        tui_dump_and_fail attach "the attached viewer shows no install progress"
    fi
    if grep -q "Waiting for the install to emit progress" "$EVIDENCE_DIR/07-reattach-viewer.txt"; then
        tui_dump_and_fail attach "the attached viewer's log pane stayed empty"
    fi

    log "detaching the viewer (q)"
    tux send-keys -t attach q
    wait_session_end attach \
        || tui_dump_and_fail attach "the viewer did not exit after detach"
    local exit_code
    exit_code="$(docker_exec "cat /root/tui-attach.exit 2>/dev/null" || echo x)"
    [[ "$exit_code" == "0" ]] \
        || fail "viewer attach exited with code $exit_code (expected 0)"
    unit_running \
        || fail "the install unit STOPPED when the viewer detached (ActiveState=$(unit_state))"
    pass "tui-attach: 'install' re-run attached the live viewer; detach kept the unit running"
}

wait_session_end() { # wait_session_end <session>
    local session="$1" deadline=$(( $(date +%s) + TIMEOUT_TUI ))
    while (( $(date +%s) < deadline )); do
        if ! tux has-session -t "$session" 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# The unit must survive its viewer session dying. We attach a journal-watch
# (the same process the TUI spawns), kill it, and assert the unit is still
# running — then re-attach.
phase_kill_reattach() {
    require_unit_running "kill/reattach"
    # Attach a viewer session (a journal-watch, as the TUI does).
    docker_exec 'nohup journalctl -u vmangos-install -n 5 -f >/tmp/viewer.log 2>&1 &' >/dev/null 2>&1
    sleep 3
    require_unit_running "kill/reattach (while viewer attached)"
    log "unit state while viewer attached: $(unit_state)"
    # Kill the viewer session (simulates the user closing the TUI / Ctrl+C).
    docker_exec "pkill -f 'journalctl -u vmangos-install'" >/dev/null 2>&1 || true
    sleep 3
    require_unit_running "kill/reattach (after viewer killed)"
    log "unit state after viewer killed: $(unit_state)"
    # Re-attach: a fresh journal read must work.
    docker_exec 'journalctl -u vmangos-install -n 3 --no-pager' >/dev/null 2>&1 \
        || fail "re-attach failed (journalctl could not read the unit)"
    pass "kill/reattach: the unit survives the viewer session dying"
}

# Force a failure (stop the unit) once the first phase checkpoint exists,
# drive the runner's retry path (stop + reset-failed + start — exactly what
# the FailureScreen's Retry button runs), and VERIFY the resume:
#   * the retried invocation reports resuming from the captured checkpoint,
#   * no completed phase re-ran (prerequisites never starts again),
#   * the checkpoint then advances past where the failure happened.
phase_failure_retry() {
    require_unit_running "failure/retry"
    log "waiting for the first phase checkpoint (prerequisites runs real apt)..."
    local cp_before
    cp_before="$(wait_checkpoint_past 0 "$TIMEOUT_PREREQS")" \
        || fail "no phase checkpoint appeared within ${TIMEOUT_PREREQS}s"
    log "checkpoint before forced failure: $cp_before"
    local prereq_starts_before
    prereq_starts_before="$(journal_count 'phase=prerequisites event=start')"
    log "prerequisites start markers so far: $prereq_starts_before"

    log "forcing a failure (systemctl stop)..."
    docker_exec 'systemctl stop vmangos-install.service' >/dev/null 2>&1 || true
    sleep 3
    if unit_running; then
        fail "forced failure did not stop the unit (ActiveState=$(unit_state))"
    fi
    log "unit state after forced failure: $(unit_state)"

    # The runner's retry path: installer_unit_stop (stop + reset-failed) then
    # installer_unit_start — the command the FailureScreen's Retry runs.
    log "driving the retry (installer_unit_stop + installer_unit_start)..."
    docker_exec "
        set -u
        source $MANAGER_PREFIX/lib/installer.sh
        installer_unit_stop
        installer_unit_start '$SECRETS_FILE' '$SETUP_SCRIPT'
    " || fail "retry launch failed"
    sleep 5
    require_unit_running "failure/retry (after retry)"
    log "unit state after retry: $(unit_state)"

    # Resume verification 1: the retried invocation says it resumed from the
    # checkpoint captured before the failure.
    local resumed
    resumed="$(journal_count "Resuming from checkpoint: $cp_before")"
    [[ "$resumed" -ge 1 ]] \
        || fail "retry did not resume: no 'Resuming from checkpoint: $cp_before' in the journal"
    log "journal shows 'Resuming from checkpoint: $cp_before' ($resumed time(s))"

    # Resume verification 2: no completed phase re-ran — prerequisites never
    # started again after the retry.
    local prereq_starts_after
    prereq_starts_after="$(journal_count 'phase=prerequisites event=start')"
    [[ "$prereq_starts_after" == "$prereq_starts_before" ]] \
        || fail "retry re-ran prerequisites from scratch ($prereq_starts_after starts vs $prereq_starts_before before)"

    # Resume verification 3: the checkpoint advances from where it was —
    # the resumed run continues the install instead of idling or resetting.
    local cp_after
    cp_after="$(wait_checkpoint_past "$(checkpoint_rank "$cp_before")" "$TIMEOUT_ADVANCE")" \
        || fail "checkpoint never advanced past $cp_before after the retry"
    log "checkpoint advanced after retry: $cp_before -> $cp_after"

    pass "failure/retry: stopped then restarted via the runner's retry path; resumed from $cp_before (now $cp_after), no completed phase re-ran"
}

# Stream the install's markers from the journal until it ends (done or error),
# a unit death, or the timeout. Prints the newest marker each poll so progress
# is visible. Returns: 0 completed, 1 error marker, 2 timeout, 3 unit left
# active states without a terminal marker.
phase_watch() {
    local timeout="${SMOKE_WATCH_TIMEOUT:-$TIMEOUT_INSTALL}"
    local deadline=$(( $(date +%s) + timeout ))
    log "watching markers (timeout ${timeout}s)..."
    local state latest last_logged=""
    while (( $(date +%s) < deadline )); do
        state="$(unit_state)"
        latest="$(latest_marker)"
        # Log only new markers (avoid spamming the same line each poll).
        if [[ -n "$latest" && "$latest" != "$last_logged" ]]; then
            log "marker: $latest"
            last_logged="$latest"
        fi
        if [[ "$latest" == *"phase=install event=done"* ]]; then
            pass "install completed (terminal marker)"
            return 0
        fi
        if [[ "$state" != "active" && "$state" != "activating" && "$state" != "unknown" ]]; then
            log "unit left active states (ActiveState=$state)"
            return 3
        fi
        sleep 5
    done
    log "watch timeout reached (last marker: ${latest:-none})"
    return 2
}

# Verify completion: the terminal marker is present and auth+world are active.
phase_completion() {
    local latest; latest="$(latest_marker)"
    [[ "$latest" == *"phase=install event=done"* ]] \
        || fail "no completion marker (latest: ${latest:-none})"
    log "completion marker: $latest"
    local auth_state world_state
    auth_state="$(docker_exec 'systemctl show -p ActiveState auth.service --value' 2>/dev/null || echo unknown)"
    world_state="$(docker_exec 'systemctl show -p ActiveState world.service --value' 2>/dev/null || echo unknown)"
    log "auth: $auth_state | world: $world_state"
    [[ "$auth_state" == "active" ]] || fail "auth is not active (ActiveState=$auth_state)"
    [[ "$world_state" == "active" ]] || fail "world is not active (ActiveState=$world_state)"
    # Extract the realmlist-relevant fields from the completion marker.
    local server_ip auth_port world_port
    server_ip="$(grep -oE 'server_ip=[^ ]+' <<<"$latest" | cut -d= -f2)"
    auth_port="$(grep -oE 'auth_port=[^ ]+' <<<"$latest" | cut -d= -f2)"
    world_port="$(grep -oE 'world_port=[^ ]+' <<<"$latest" | cut -d= -f2)"
    log "realmlist target: world=$world_port server_ip=$server_ip (auth=$auth_port)"
    # Verify the realmlist row against the database itself, not just against
    # the marker the installer wrote: the realm address must match the
    # marker's server_ip and the realm port must match its world_port.
    # Root connects over the local socket inside the container.
    local realm_row realm_addr realm_port
    realm_row="$(docker_exec "
        set -u
        [ -f $SECRETS_FILE ] && . $SECRETS_FILE
        mysql -u root -N -B -e \"SELECT address, port FROM \${AUTHDB:-auth}.realmlist WHERE id=1;\"
    " 2>/dev/null | tail -n1 || true)"
    realm_addr="$(cut -f1 <<<"$realm_row")"
    realm_port="$(cut -f2 <<<"$realm_row")"
    [[ -n "$realm_addr" && -n "$realm_port" ]] \
        || fail "realmlist query returned no row (got: '$realm_row')"
    [[ "$realm_addr" == "$server_ip" ]] \
        || fail "realmlist address ($realm_addr) does not match the marker's server_ip ($server_ip)"
    [[ "$realm_port" == "$world_port" ]] \
        || fail "realmlist port ($realm_port) does not match the marker's world_port ($world_port)"
    log "realmlist row verified: address=$realm_addr port=$realm_port matches the marker"
    snapshot_assert_frozen_starts
    pass "completion: terminal marker + auth+world active + realmlist row verified"
}

# After a completed run the unit is collected (its name is free again). The
# runner — the same path a second `install` uses — must be able to re-create
# the unit name. The re-created unit is stopped again right after: on a real
# host a re-install goes through the wizard's gate; here the point is the
# name, not another 4-hour install.
phase_name_recreation() {
    if unit_running; then
        fail "name-recreation precondition: unit still running (ActiveState=$(unit_state))"
    fi
    log "re-creating the unit name via the runner (installer_unit_start)"
    docker_exec "
        set -u
        source $MANAGER_PREFIX/lib/installer.sh
        installer_unit_start '$SECRETS_FILE' '$SETUP_SCRIPT'
    " || fail "runner refused to re-create the unit name after a completed run"
    local deadline=$(( $(date +%s) + 120 )) starts
    while (( $(date +%s) < deadline )); do
        starts="$(journal_count 'phase=prerequisites event=start')"
        if [[ "$starts" -ge 2 ]]; then
            log "the re-created unit is running our installer (prerequisites start markers: $starts)"
            break
        fi
        sleep 3
    done
    [[ "${starts:-0}" -ge 2 ]] \
        || fail "the re-created unit never started the install script"
    require_unit_running "name-recreation (running)"
    # Stop it again through the runner: this is a name exercise, not an
    # install. The completed install's services are untouched by it.
    docker_exec "
        set -u
        source $MANAGER_PREFIX/lib/installer.sh
        installer_unit_stop
    " || fail "runner could not stop the re-created unit"
    sleep 3
    if unit_running; then
        fail "re-created unit still running after installer_unit_stop"
    fi
    pass "name-recreation: the runner re-created the unit name after a completed run (and stopped it)"
}

# Ensure the dashboard venv can run the pytest suite. The bootstrap only
# installs the runtime deps (textual), so add pytest once if it is missing.
ensure_venv_pytest() {
    local venv_bin="$MANAGER_PREFIX/.venv-dashboard/bin"
    if docker_exec "\"$venv_bin/python3\" -m pytest --version >/dev/null 2>&1" 2>/dev/null; then
        return 0
    fi
    log "installing pytest into the dashboard venv..."
    docker_exec "\"$venv_bin/python3\" -m pip install --quiet pytest" \
        || fail "could not install pytest into the dashboard venv"
}

# Re-run the viewer's async suite N times as a stability gate. The #113
# unit-state race is fixed (window exceeds the checker's query timeout; the
# wait predicates gate on the screen text), so any failure is unknown and
# fails the smoke — its output is captured for the report.
phase_flake_watch() {
    ensure_venv_pytest
    local n="${SMOKE_FLAKE_RUNS:-5}" i pass_count=0 rc
    log "flake-watch: running the viewer async suite $n times (any failure fails the smoke)..."
    for (( i=1; i<=n; i++ )); do
        # The run's exit status is pytest's own (output goes to a file — a
        # pipeline's tail can never mask it again).
        rc=0
        docker_exec "
            cd /src/manager
            PATH=$MANAGER_PREFIX/.venv-dashboard/bin:\$PATH \
            PYTEST_CACHE_DIR=/tmp/pytest-cache PYTHONDONTWRITEBYTECODE=1 \
            python3 -m pytest tests/test_wizard.py -q --tb=short -rf > /root/flake-run-$i.log 2>&1
        " || rc=$?
        if (( rc == 0 )); then
            pass_count=$((pass_count+1))
            continue
        fi
        log "test failure in run $i — full output:"
        docker_exec "cat /root/flake-run-$i.log" >&2 || true
        fail "flake-watch: test failure in run $i (no known flakes are tolerated since #113 was fixed)"
    done
    log "flake-watch: $pass_count/$n runs green, 0 failures"
    pass "flake-watch: $n runs green (no failures tolerated)"
}

# ---------------------------------------------------------------------------
# Snapshot phases (#116)
# ---------------------------------------------------------------------------

# Commit the container into a snapshot image once its install checkpoint
# has passed SMOKE_SNAPSHOT_AFTER. The image embeds everything the finished
# phases produced — the install root (checkpoint, build, extracted data),
# the databases, the installed manager, the secrets — so a re-smoke with
# --from-snapshot resumes the install from the embedded checkpoint instead
# of re-running them. Services are captured as-is (as after a power cut);
# MySQL recovers on the next boot. Works in parallel with a running smoke
# (same container name) or against a kept container whose checkpoint
# already satisfies the target.
phase_snapshot() {
    require_docker
    docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 \
        || die "snapshot: container $CONTAINER_NAME does not exist (set it up first)"
    local after="$SNAPSHOT_AFTER" rank tag cp
    rank="$(checkpoint_rank "$after")"
    (( rank >= 1 )) \
        || die "snapshot: unknown checkpoint '$after' (SMOKE_SNAPSHOT_AFTER)"
    tag="${SNAPSHOT_TAG:-$(snapshot_default_tag "$after")}"
    if unit_running; then
        log "snapshot: install unit running — waiting for checkpoint $after..."
        cp="$(wait_checkpoint_past $(( rank - 1 )) "$TIMEOUT_INSTALL")" \
            || fail "snapshot: the checkpoint never passed $after within ${TIMEOUT_INSTALL}s"
    else
        cp="$(checkpoint_read)"
        [[ -n "$cp" && "$(checkpoint_rank "$cp")" -ge "$rank" ]] \
            || fail "snapshot: unit not running and checkpoint '${cp:-none}' has not passed $after"
    fi
    log "snapshot: checkpoint $cp passed $after — committing $CONTAINER_NAME as $tag"
    docker commit "$CONTAINER_NAME" "$tag" >/dev/null
    pass "snapshot: image $tag (checkpoint $cp) — re-smoke with --from-snapshot $tag"
}

# Freeze the journal start-marker counts of every phase completed before the
# embedded checkpoint; completion compares against them, so a re-smoke can
# prove build/extraction never re-ran. Counts are frozen (not assumed zero)
# because the snapshot carries the original run's journal.
snapshot_freeze_starts() {
    local cp_rank p r counts=""
    cp_rank="$(checkpoint_rank "$(checkpoint_read)")"
    for p in prerequisites database source build config extraction; do
        r="$(phase_done_rank "$p")"
        (( r >= 1 && r <= cp_rank )) || continue
        counts+="$p $(journal_count "phase=$p event=start")"$'\n'
    done
    mkdir -p "$EVIDENCE_DIR"
    printf '%s' "$counts" > "$EVIDENCE_DIR/snapshot-start-baseline.txt"
    log "resume-install: froze embedded-phase start baselines ($EVIDENCE_DIR/snapshot-start-baseline.txt)"
}

snapshot_assert_frozen_starts() {
    [[ -n "$FROM_SNAPSHOT" ]] || return 0
    local baseline="$EVIDENCE_DIR/snapshot-start-baseline.txt" p before after
    [[ -f "$baseline" ]] \
        || fail "completion: no snapshot baseline (did resume-install run?)"
    while read -r p before; do
        [[ -n "$p" ]] || continue
        after="$(journal_count "phase=$p event=start")"
        [[ "$after" == "$before" ]] \
            || fail "completion: phase $p re-ran from the snapshot ($after start markers vs $before at resume time — the resume skipped nothing)"
        log "snapshot check: $p never re-ran ($after start marker(s))"
    done < "$baseline"
}

# Launch phase of the snapshot flow: start the install from the checkpoint
# embedded in the snapshot image through the runner — the same path Retry
# and a second `install` take. The clean flow's tui-launch is skipped here:
# its gate must be clean, and a snapshot deliberately carries an
# install-in-progress state.
phase_resume_install() {
    if unit_running; then
        fail "resume-install precondition: an install unit is already running"
    fi
    local cp
    cp="$(checkpoint_read)"
    [[ -n "$cp" ]] \
        || fail "resume-install: no install checkpoint in the container (start from a snapshot: --from-snapshot TAG)"
    docker_exec "test -f '$SECRETS_FILE'" >/dev/null 2>&1 \
        || fail "resume-install: no secrets file at $SECRETS_FILE in the container"
    log "embedded checkpoint: $cp"
    snapshot_freeze_starts
    local resumed_before
    resumed_before="$(journal_count "Resuming from checkpoint: $cp")"
    log "starting the install via the runner (installer_unit_start)..."
    docker_exec "
        set -u
        source $MANAGER_PREFIX/lib/installer.sh
        installer_unit_start '$SECRETS_FILE' '$SETUP_SCRIPT'
    " || fail "resume-install: the runner refused to start the unit"
    sleep 5
    require_unit_running "resume-install"
    local resumed_after
    resumed_after="$(journal_count "Resuming from checkpoint: $cp")"
    (( resumed_after > resumed_before )) \
        || fail "resume-install: no new 'Resuming from checkpoint: $cp' in the journal (the install restarted instead of resuming)"
    log "journal shows 'Resuming from checkpoint: $cp'"
    pass "resume-install: unit running from checkpoint $cp; embedded-phase baselines frozen"
}

phase_teardown() {
    log "tearing down the container (keeping the client-data cache on the host)"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    pass "container removed (screen evidence kept at $EVIDENCE_DIR)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

usage() {
    sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --phase)        PHASE="${2:-}"; shift 2 ;;
            --client-data)  CLIENT_DATA="${2:-}"; shift 2 ;;
            --container)    CONTAINER_NAME="${2:-}"; shift 2 ;;
            --image)        IMAGE_NAME="${2:-}"; shift 2 ;;
            --repo)         REPO_ROOT="${2:-}"; shift 2 ;;
            --from-snapshot)
                # Optional value: a snapshot tag; without one, the default
                # tag for SMOKE_SNAPSHOT_AFTER.
                if [[ -n "${2:-}" && "${2:-}" != -* ]]; then
                    FROM_SNAPSHOT="$2"; shift 2
                else
                    FROM_SNAPSHOT="$(snapshot_default_tag "$SNAPSHOT_AFTER")"; shift
                fi ;;
            --keep)         KEEP=1; shift ;;
            -h|--help)      usage 0 ;;
            *)              usage 2 ;;
        esac
    done
}

run_phase() {
    local name="$1"
    log "=== phase: $name ==="
    case "$name" in
        build-image)     phase_build_image ;;
        setup)           phase_setup ;;
        manager)         phase_manager ;;
        tui-launch)      phase_tui_launch ;;
        tui-attach)      phase_tui_attach ;;
        kill-reattach)   phase_kill_reattach ;;
        failure-retry)   phase_failure_retry ;;
        watch)           phase_watch ;;
        completion)      phase_completion ;;
        name-recreation) phase_name_recreation ;;
        flake-watch)     phase_flake_watch ;;
        snapshot)        phase_snapshot ;;
        resume-install)  phase_resume_install ;;
        teardown)        phase_teardown ;;
        *)               die "unknown phase: $name" ;;
    esac
}

main() {
    parse_args "$@"
    require_docker

    if [[ "$PHASE" == "all" ]]; then
        # The wizard TUI launches the install; the scenarios run while the
        # unit is active (viewer attach, kill/reattach, the forced failure +
        # verified retry); the blocking watch then runs to completion.
        local phases
        if [[ -n "$FROM_SNAPSHOT" ]]; then
            # Snapshot flow (#116): no image build (the snapshot exists) and
            # no tui-launch (its gate must be clean; a snapshot deliberately
            # carries an install-in-progress state) — resume-install starts
            # the install from the embedded checkpoint instead, immediately
            # followed by the verified-retry scenario so it lands inside the
            # short db-import window. Everything else runs unchanged.
            phases=(setup manager resume-install failure-retry tui-attach kill-reattach watch completion name-recreation flake-watch)
        else
            phases=(build-image setup manager tui-launch tui-attach kill-reattach failure-retry watch completion name-recreation flake-watch)
        fi
        if (( KEEP )); then
            log "--keep set: skipping teardown"
        else
            phases+=(teardown)
        fi
        local p
        for p in "${phases[@]}"; do
            run_phase "$p"
        done
        pass "smoke complete"
    else
        run_phase "$PHASE"
    fi
}

main "$@"
