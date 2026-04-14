# Draft Issue: Release B TUI Polish And Control-Surface Expansion

## Summary

The Textual dashboard shipped and is valuable, but it is still narrower than the CLI and needs at least a few more polish passes before it fully earns its position as the main selling point of Manager.

This draft is intentionally for a **later GitHub issue**, not immediate coding scope. The next gate remains:

1. Full teardown of host `10.0.1.6`
2. Fresh reprovision using the revised installer scripts
3. End-to-end validation on the rebuilt host

Only after that pass should the next TUI-focused issue be opened and worked.

## Why This Follow-Up Exists

Current README positioning is correct: the TUI is the product’s headline experience.

Current implementation reality is narrower:

- the dashboard aggregates `server status`, `logs status`, and `account list --online`
- the only interactive actions are `server start`, `stop`, `restart`, `refresh`, and theme toggle
- several major CLI capabilities are still absent from the dashboard entirely
- the `Player Details` presentation is currently too cramped and was already judged unusable in the exported README screenshot review

## Verified Current TUI Surface

Verified from `manager/lib/dashboard.py` and dashboard tests:

- service overview panel
- host metrics panel
- alerts and recent events panel
- online players table
- player details panel
- start / stop / restart hotkeys
- refresh hotkey
- light / dark theme toggle

Verified backend aggregation today:

- `server status`
- `logs status`
- `account list --online`

## Verified Gaps To Track

### 1. Player Details Panel Needs Layout Rework

The current `Player Details` panel is not presentation-ready.

Observed implementation constraints:

- the dashboard uses a rigid 2x2 grid
- the player area is a single panel split between table and details
- `#player-details` is hard-coded to a short fixed height
- the detail payload is minimal and does not justify the amount of screen stress it creates

Follow-up intent:

- redesign the player area so details are readable at normal terminal sizes
- avoid the current cramped split that mangles the panel in screenshots
- decide whether player details should be a side card, modal, expandable footer, or dedicated view

### 2. Backup Workflows Have No TUI Surface

CLI capability exists, but the dashboard does not expose it.

Missing TUI coverage:

- backup status / last backup summary
- backup list
- backup create-now action
- backup verify action and result visibility
- backup retention / cleanup visibility
- restore should likely remain guarded, but at minimum status and drill-in should exist

### 3. Account Management Is Only Partially Surfaced

Current TUI account coverage is limited to online-account listing.

Missing TUI coverage:

- account create
- account password reset
- account GM level changes
- ban / unban actions
- better account drill-down than the current short details panel
- clearer distinction between online players and account administration

### 4. Config Commands Have No TUI Surface

The CLI now has meaningful config operations, but the dashboard does not expose them.

Missing TUI coverage:

- config validation status
- config show / inspect workflow
- config detect workflow for adopted installs
- clear surfacing of key runtime paths and service names

### 5. Dashboard IA Is Still Too Status-Centric

The current dashboard is effectively a status console with a small action strip, not yet a broader Manager console.

Missing information architecture work:

- stronger separation between monitoring, operations, backup, accounts, and configuration
- navigation model for non-status workflows
- a deliberate home screen that can still feel “top-like” without hiding administrative functions

### 6. Screenshot / Demo Readiness Still Needs Work

The README screenshot matters for adoption, and the current UI still needs polish before it consistently sells the product well.

Follow-up should include:

- screenshot-aware layout cleanup
- typography and spacing polish
- better balance between dense metrics and readable detail panes
- confirmation that the exported screenshot reflects the product at its best, not just its current state

## Suggested Scope For The Later Issue

Keep the later issue focused on **TUI polish and control-surface expansion**, not general backend work.

Suggested acceptance shape:

- player details panel is redesigned and readable in common terminal sizes
- dashboard navigation expands beyond status-only monitoring
- dashboard exposes backup workflows at least for status, list, create, and verify
- dashboard exposes account administration workflows beyond online listing
- dashboard exposes config validation / inspection entry points
- screenshot/export output is clean enough for README and release materials
- tests cover the new dashboard aggregation or action seams pragmatically

## Explicit Non-Goals For That Later Issue

- do not fold this into installer validation or fresh-host reprovision work
- do not start this before the `10.0.1.6` teardown + reprovision e2e pass
- do not rewrite the CLI backend just to suit the TUI
- do not chase Release C monitoring depth here unless the TUI specifically needs already-existing status data surfaced cleanly

## Useful Code References

- `manager/lib/dashboard.py`
- `manager/lib/dashboard.sh`
- `manager/bin/vmangos-manager`
- `manager/tests/run_tests.sh`

## Notes For The Eventual GitHub Issue Body

When this is converted into a real issue, keep the body grounded in the current codebase:

- call out that the dashboard already ships and is useful
- frame this as polish + control-surface expansion, not a restart
- explicitly mention that backend CLI features already exist and should be reused
- link the work to README/demo quality and operator adoption
