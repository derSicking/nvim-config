# Worktime — work time tracker for Neovim

Record when you work, on which project and ticket, directly from Neovim. Derive
weekly hours per project/ticket and export to CSV.

## Data model

Timestamp-ordered TSV event log, one event per line:

```
TIMESTAMP ␉ EVENT ␉ PROJECT ␉ TICKET ␉ MESSAGE
```

- `TIMESTAMP`: `YYYY-MM-DDTHH:MM:SSZ`, stored in UTC; fixed width, so lines sort
  lexicographically — and correctly across timezones. Commands accept and
  display local time, converted at the edges.
- `EVENT`: `start | end`
- `PROJECT` / `TICKET`: describe the block starting at this line; recorded on
  `start`, empty on `end`
- `MESSAGE`: optional, free-form; tabs/newlines sanitized to keep TSV valid

### Unambiguity invariant

Events strictly alternate `start`/`end`. The log begins with `start` (or is
empty) and ends with `end` (closed) or `start` (open = recording now).

Every valid log therefore has exactly one reading: work blocks are `start` →
`end` pairs; everything between an `end` and the next `start` is not-work
(break). Ambiguous sequences like `start A | start B | end` (project switch vs.
forgotten end) are unrepresentable — every mutation is validated against the
current log and committed atomically, so the file never exists in a state with
two possible interpretations.

### Blocks and gaps

| Sequence        | Meaning                    |
| --------------- | -------------------------- |
| `start` … `end` | work block, hours counted  |
| `end` … `start` | gap, not counted (break)   |
| tail is `start` | recording now (open block) |
| tail is `end`   | not recording              |

Parsing is a streaming state machine over lines — hold the open block, close it
on the next `end` — no sort, no full-file load. Malformed files (alternation
violated, e.g. after a hand-edit) are reported by `:WorkValidate`.

### Write rules

All mutations validate against the current log, then commit atomically (temp
file + `rename()`). Live events (time = now) are appends at the tail; backdated
ones insert at their sorted position — same rules either way.

| Mutation                           | Valid iff                                                                    | Result                               |
| ---------------------------------- | ---------------------------------------------------------------------------- | ------------------------------------ |
| `WorkStart [time]`                 | tail is `end`/empty ∧ `time` > tail ts ∧ `time` ≤ now                        | one `start` at tail                  |
| `WorkEnd [time]`                   | tail is `start` ∧ `time` ≥ that start's ts ∧ `time` ≤ now                    | one `end` at tail                    |
| `WorkAdd start <s> end <e>`        | fits in a gap: prev is `end`/∅, next is `start`/∅, prev_ts < s < e < next_ts | work pair into gap                   |
| `WorkAdd end <e> start <s>`        | fits in a block: prev is `start`, next is `end`/∅, prev_ts < e < s < next_ts | break pair into block                |
| `WorkChange [ticket] [message...]` | tail is `start` (recording); live-only, no backdating                        | `end` + `start` at tail, both at now |

- `WorkAdd start … end` records forgotten work in a gap.
- `WorkAdd end … start` records forgotten time off inside a block — this also
  splits a block (`start 9 | end 17` + `end 10` `start 11` →
  `start 9 | end 10 | start 11 | end 17`) and, at the tail of an open block, is
  exactly "break now, resume now" in one atomic step. The resumed `start` can
  carry a new ticket/project.
- Out-of-window pairs are rejected with the allowed range in the message — never
  silently clamped. Future timestamps are rejected.
- A break pair needs a containing block, a work pair needs a gap. The
  alternation invariant stays closed under all four mutations.
- `WorkChange` is the zero-gap case of `WorkAdd end … start` at the tail: it
  closes the current block and opens a new one with the given ticket/message,
  both lines at the current time. Backdated ticket changes go through
  `WorkAdd end <e> start <s>` instead.

### Why TSV, timestamp-ordered

- Live events always append — they're the newest, so the common path is a pure
  append, immune to partial-write corruption.
- Every mutation is validated against the current log and committed atomically
  (temp file + rename), so the file never exists in an invalid or ambiguous
  state.
- Backfilled/edited entries insert at their chronological position via the same
  rewrite path. Rare and safe.
- Reads are streaming: for a time window (e.g. one week) we byte-bisect into the
  file and parse only the slice — ISO timestamps compare lexicographically, so
  the bisect is plain string comparison.
- The raw file reads chronologically, greppable, hand-editable.

## Storage

`~/.local/share/nvim/worktime/log.tsv` (XDG data dir). The data dir is a git
repo — `log.tsv` is the only tracked file. File is kept timestamp-ordered; all
rewrites use temp file + atomic rename. (See Sync below.)

## Sync (cross-machine)

Optional: set `remote` in the config and the plugin manages `origin` (adds it on
first run). Without it, everything works purely local.

The remote is the source of truth. Every mutation:

1. `git fetch` — updates the remote state shown in the statusline
2. if origin is ahead: `pull --rebase`; on conflict: abort, keep local, mark
   diverged, notify loudly — never auto-resolve, never lose data
3. re-read the log (it may have changed) and re-validate the mutation against
   the fresh state
4. apply → commit → push

Offline: writes still apply locally and are committed; the statusline and a
notification warn about divergence risk (another machine may have written).
Reconnect and run `:WorkSync` to reconcile.

Statusline remote state: synced / push pending / remote ahead / diverged /
offline.

Commands: `WorkSync` (fetch + rebase + push now), `WorkPush` (push now).

Conflicts are resolved by hand (`:WorkValidate` + edit); the alternation
invariant keeps a diverged log detectable and unambiguous once repaired.
Concurrent writes from two machines to the same region are the only case that
needs this.

## Config

External config, deliberately outside the dotfiles repo — project dirs and
client names are machine-specific. Lua table, loaded with `dofile`, so comments
and helpers are allowed.

`~/.config/nvim-worktime/config.lua`:

```lua
return {
  remote = "git@github.com:you/worktime.git", -- optional; omit for local-only
  projects = {
    ["client-a"] = {
      dirs = { "~/code/client-a", "~/code/client-a-tools" },
      weekly_target = 20, -- hours
    },
  },
}
```

On first load the plugin creates the dir and an example config with a comment
header, then notifies where it lives.

Project detection: longest-prefix match on cwd; if nothing matches, fall back to
the cwd basename. The detected project is always shown in the command's
notification so a wrong match is visible immediately.

## Commands

| Command                                           | Purpose                                             | Step |
| ------------------------------------------------- | --------------------------------------------------- | ---- |
| `WorkStart [time] [ticket] [message...]`          | start a work block, optionally backdated            | 1    |
| `WorkEnd [time] [message...]`                     | end the current block, optionally backdated         | 1    |
| `WorkStatus`                                      | current state + today's totals                      | 1    |
| `WorkAdd start <s> end <e> [ticket] [message...]` | forgotten work into a gap                           | 3    |
| `WorkAdd end <e> start <s> [message...]`          | forgotten break inside a block                      | 3    |
| `WorkChange [ticket] [message...]`                | switch ticket while recording (end + start at tail) | 3    |
| `WorkLog`                                         | viewer buffer                                       | 4    |
| `WorkExport`                                      | CSV with derived values                             | 5    |
| `WorkSync` / `WorkPush`                           | sync with remote now (fetch+rebase+push / push)     | 6    |

Optional `time` is detected by pattern (`HH:MM` or full ISO timestamp);
remaining args are ticket/message. No separate break commands — a break is an
`end` followed by a `start`, in one `WorkAdd` step or two live commands.

## Reminders

- `VimEnter` + `VimResume` (Ctrl-Z suspend): if not recording, suggest
  `:WorkStart`
- `VimLeavePre`: warn if a block is still open
- Statusline segment: recording state + remote state (e.g.
  `⏱ work · client-a · 3.2h ⇡` — synced / push pending / remote ahead / diverged
  / offline)

## Export (derived values)

CSV rows: ISO week × project → hours, weekly target, diff. Ticket breakdown: ISO
week × project × ticket → hours. Written to the data dir.

## Non-goals

- No GUI / web / calendar integration
- No automatic resolution of diverged histories (two machines writing the same
  region) — manual repair, detected by `:WorkValidate`
- No billing-grade accuracy guarantees — it's a log, not a timesheet system

## Build status

| Step | Content                                                             | Status  |
| ---- | ------------------------------------------------------------------- | ------- |
| 0    | README + scaffold                                                   | done    |
| 1    | MVP: config + storage + commands, wired into `lua/init.lua`         | done    |
| 2    | reminders + statusline segment                                      | pending |
| 3    | `WorkAdd` backfill                                                  | pending |
| 4    | `WorkLog` viewer                                                    | pending |
| 5    | `WorkExport` CSV                                                    | pending |
| 6    | sync: git remote, UTC storage, remote status, `WorkSync`/`WorkPush` | pending |
| 7    | extras (below)                                                      | pending |

## Backlog / ideas

- weekly summary notification (`:WorkSummary`)
- month view in the viewer
- idle detection → suggest a break
- git branch → ticket hint on `start`
- project rename (updates log + config)
- `:WorkValidate` — check the log for malformed/out-of-order lines and help
  repair them by hand
- edit an existing entry (project/ticket/message) — atomic, re-validated
- lockfile against concurrent nvim instances writing at once
- fuzzy time parsing for `time` args: "17" → today 17:00, "yesterday 10:29",
  "tuesday 11" → 11:00, etc. — for `WorkStart`/`WorkEnd`/`WorkAdd`
- interactive `WorkAdd` (snacks picker): show the last few log entries, user
  selects the seam after which to insert; the UI then displays the allowed
  bounds for start/end live while typing (same window the validator computes),
  day implied by the selected seam — show the date when the window spans days
- ticket selection for `WorkStart`/`WorkAdd`: command-line completion
  (`customlist`) with recent tickets from the same project, deduped,
  most-recent-first, falling back to all projects; snacks picker when no ticket
  is given (folds into the interactive `WorkAdd` flow)
