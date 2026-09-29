# Two machines, one vault

Date: 2026-09-28. Approved by the user in conversation, in two parts, together
with the four decisions recorded below. Revised on 2026-09-29: a run waits
for a remote it cannot reach at its start (decision 2, "Waiting for the
remote"). Revised again the same day, in a separate change: a job waits for
the local lock instead of skipping, the lock is taken in one step, and the
vault is checked again after the wait for the remote lock ("The local
lock"). A third change the same day hardened the lock after its second
review: items 9 to 11 of "The local lock".

## Problem

A vault can live on two machines, for example a Linux desktop and a Mac
laptop, each with its own A5N checkout and its own `config.ini`. Pages travel
through a private git remote. Raw transcripts are large, so a vault may keep
`**/raw/` out of git and copy it to cloud storage with `rclone copy
--immutable` instead, every machine holding a full local copy.

Today that loop is manual: before a run, `git pull --rebase` and an rclone
download per project; after it, `git push` and the upload. An unattended run
cannot do those steps, so the scheduled jobs stay off on every machine that
shares a vault. This change makes A5N do the loop itself.

## Goals and non goals

Goals:

* One `[sync]` section, off by default. Off means today's behavior exactly and
  no network call at all.
* With sync on: pull before work, push after every commit, raw files copied
  both ways without ever deleting or overwriting anything, and at most one
  machine running model workers at a time.
* Every failure is either harmless and logged, or visible as a notification.
  A silently stalled pipeline is the failure this project designs against.

Non goals: more than one remote, automatic conflict resolution beyond
`log.md`, syncing `.a5n-logs/`, and moving an existing vault's raw files out
of git (that is a one time manual migration).

## Decisions taken in the conversation

1. A unit left half written by a killed run is moved to `git stash`, not
   deleted: the user may have edited the vault by hand since.
2. When the remote is unreachable at the start, layer 2 is skipped at once.
   Only a short retry is allowed (three fetch attempts, 20 seconds apart),
   because launchd starts a job missed during sleep right at wake, before the
   network is back.
   Revised on 2026-09-29: after those three attempts the run waits up to
   `sync.offline_after` seconds (15 minutes) before it goes offline. A
   systemd timer with lingering on starts a missed run at boot, before
   anyone has logged in to open the keyring that holds the git credential,
   and the three attempts end before the login. See "Waiting for the
   remote".
3. A notification fires when sync has been failing for more than 24 hours,
   counted from the FIRST failure since the last success. Counting from the
   last success would alert every Monday on a desktop that is off at weekends.
4. The interrupted unit flag, the `.gitkeep` fix, the lint prompt change and
   Linux notifications apply with sync off too. "Sync off changes nothing"
   is about the sync behavior: no network call, identical commits.

## Configuration

```ini
[sync]
enabled = no
remote = origin
branch = main
raw_remote =
lock = yes
offline_after = 900
```

* `enabled`, `lock`: `yes` or `no`, validated, because a typo like `true`
  would silently leave sync off while the user believes it is on.
* `remote`, `branch`: the git remote and branch the pages travel through.
  Must be non empty when sync is on.
* `raw_remote`: an rclone path such as `gdrive:knowledge-vault`. Each
  namespace's raw files live at `<raw_remote>/<namespace>/raw`. Empty means
  raw files travel in git (the default vault layout) and rclone is never
  called. A trailing `/` is dropped.
* `lock = no` drops the remote lock. Only safe when a single machine writes.
* `offline_after` (added 2026-09-29): seconds a run keeps trying for a
  remote it cannot reach at its start, before it works offline. A whole
  number, validated: a value like `15m` would reach a shell test and turn
  the wait off, with a complaint on stderr and nothing in the run's log.
  `0` keeps only the three quick attempts. A
  setting, unlike the other waits, because it depends on the machine: how
  long after boot its user logs in, and whether its credential needs a
  login at all.

`[schedule]`: any of `ingest`, `lint`, `digest` may be `off`. The job's timer
is then not installed, and removed if it was. A second machine sets `lint =
off` and `digest = off`, because lint reports and digests are overwritten
whole and two writers would take turns replacing each other's output.

`config.py` validates the new keys, exports `A5N_SYNC_ENABLED`,
`A5N_SYNC_REMOTE`, `A5N_SYNC_BRANCH`, `A5N_SYNC_RAW_REMOTE`,
`A5N_SYNC_LOCK`, `A5N_SYNC_OFFLINE_AFTER`, and `--check` prints one sync
line.

## Components

* `scripts/lib/sync.sh`, new. Every sync step. Sourced by the three drivers
  after they define `log` and `notify_fail` and set `VAULT`, `LOGDIR`, `LOG`
  and `LOCK`; its functions run with the vault as the working directory.
  When sync is off every function returns 0 before running any command.
* `scripts/lib/common.sh`, new. What the three drivers share that is not
  sync: the desktop notification, the interrupted unit flag and, since
  2026-09-29, the local lock.
* `scripts/daily-ingest.sh`, `scripts/weekly-lint.sh`, `scripts/digest.sh`:
  source both libraries and call them at fixed points.
* `scripts/setup.sh`, `scripts/config.py`, `scripts/prompts/weekly-lint.md`,
  `config.example.ini`, `README.md`, `README.tr.md`, `AGENTS.md`,
  `CONTRIBUTING.md`.
* `tests/sync-e2e.sh` and `tests/fake-runner.sh`, new.

## Run flow with sync on

### Start, all three drivers

1. Local lock, taken in one step and waited for while another job holds it
   (see "The local lock").
2. If A5N's own rebase was interrupted (a marker file,
   `.a5n-logs/.sync-rebase`, exists while A5N rebases), abort that rebase.
3. A rebase, merge, cherry pick or revert in progress without the marker is
   the user's work, and a HEAD that is not on `sync.branch` is the user's
   choice: notify and exit without touching anything.
4. Interrupted unit recovery (see below; runs with sync off too).
5. Manual changes are committed separately, as today.
6. Fetch `+refs/heads/<branch>:refs/remotes/<remote>/<branch>`, up to three
   attempts. If all fail, `git ls-remote --exit-code --heads` separates a
   reachable remote without the branch (a fresh remote: the first push
   creates it) from an unreachable one. An unreachable remote gets up to
   `offline_after` seconds more (see "Waiting for the remote").
   Reached or not, steps 3 and 5 run once more (added 2026-09-29): the
   fetch and its wait can take minutes and end just as somebody logs in.
   A git operation in progress or another branch stops the run untouched,
   hand edits get their own manual changes commit. Still unreachable after
   that, the run is offline.
7. Rebase local commits onto `<remote>/<branch>`. `git pull --rebase` is done
   as fetch plus rebase so that "no network" and "conflict" stay distinct. A
   conflict aborts the rebase, marks the run blocked and notifies with the
   conflicting paths: it will not resolve itself.
8. Ingest and lint: raw download for every namespace, `rclone copy
   --immutable --exclude '.*' <raw_remote>/<ns>/raw <vault>/<ns>/raw`.
   Dotfiles stay out: `.gitkeep` placeholders and the `.DS_Store` Finder
   writes are both rewritten, and to `--immutable` a rewritten file is a
   modified one; a raw file is never a dotfile (widened from `.gitkeep`
   after review). Exit code 3 (source directory not found) is a project with
   no uploads yet, not an error. Other failures notify once and the run
   continues: the queue only looks at local raw files, so a missing download
   delays a unit at most.
9. Ingest and lint: one attempt at the remote lock.

Namespaces are every vault root directory holding `sources/`, plus every
configured project, the same rule the lint uses.

### Waiting for the remote

Added on 2026-09-29. A systemd timer with `Persistent=true` starts a run the
machine was off for as soon as the user manager starts, and with lingering
on that is at boot, before anyone logs in. On the first machine such a run
started 4 seconds after boot, and the login came 52 and 53 seconds after
boot on the two boots before this change. Its git credential comes from
`gh`, which keeps its token in the GNOME keyring; the keyring opens at
login, and gh 2.97.0 waits up to 60 seconds for it. When it fails at once,
the three attempts are over in about 45 seconds, before the login. Every
such run went offline, and an offline lint or digest waits a week or a
month for its next slot, because the timer has already recorded the run.

After the three attempts, until `offline_after` seconds after the first:

1. Every 20 seconds the run touches the local lock, so a long wait never
   looks stale, and asks `loginctl show-user <uid> -p State --value`.
2. `lingering` means nobody is logged in: the run waits for a login and asks
   the remote nothing, since every fetch would ask the credential helper
   for a locked keyring.
3. Any other answer, no answer, or no loginctl at all (macOS starts agents
   inside the login session): one more fetch attempt.
4. When the time is up while the run still waits for a login, one last
   attempt anyway, for a credential that needs no login, such as an ssh key.

Reached: a log line says after how many seconds, and the start goes on as
above. Not reached: after the vault check below, the run is offline as
before. The local lock is held throughout, as during the wait for the
remote lock. `offline_after = 0` skips the wait.

Either way the run then asks sync_recover's questions about the vault
again, after every fetch at the start and not only after a wait, because
the wait can end just as somebody logs in and starts working, and the
quick attempts alone can take minutes when git hangs. A git operation in
progress or another branch stops the run
untouched, as at the start, and hand edits made meanwhile get a manual
changes commit of their own (one helper in `lib/common.sh`, shared with the
drivers' commit before the start). Found in review: without it a hand edit
made git refuse the rebase, a conflict that was not there, and layer 2 was
skipped; a rebase started by hand was aborted by A5N's own; another branch
checked out meanwhile was rebased, processed and pushed to the sync branch.
The digest traps TERM, INT and HUP like the other drivers now, so a stop
during its wait removes the local lock and ends with a status the unit
reads as a stop.

### The local lock

Added on 2026-09-29, as a change of its own. The three jobs share
`.a5n-logs/.lock` because they commit into one git tree. A job that found it
held was skipped, and a timer with `Persistent=true` starts every run the
machine was off for at once, about four seconds after boot: the job that
lost was skipped until its next slot, a day for the ingest, a week for the
lint, a month for the digest, since the timer had already recorded the run.
On 2026-09-28 a lint catch-up held the lock from 08:57:08 to 09:28:36 after
a boot at 08:57:04; an ingest timer at 09:07 would have lost its day. The
wait for the remote at the start made such windows longer still. And the
lock was taken in two steps, a look and, after the trap setup, a write, so
two runs starting in the same instant could both pass the look.

1. The three copies of the lock code in the drivers became one set of
   functions in `lib/common.sh`.
2. The lock is created in one step: with zsh's `noclobber`, `>` opens the
   file with `O_EXCL` (checked with strace), so of two runs that create it
   at once exactly one succeeds.
3. A lock held by a live run is waited for: a look every 10 seconds, at
   most two hours. Two hours covers an ingest (34 to 95 minutes observed) or
   a lint (about 30). The bound is a constant in the code, not a setting:
   it follows A5N's own run lengths, not the machine, like the one hour wait
   for the remote lock. The environment overrides `A5N_LOCK_WAIT` and
   `A5N_LOCK_POLL` exist for the tests. All three jobs wait: one rule, and a
   lost ingest day delays a whole day's cap of sessions while a backlog is
   worked off. The service units are `Type=oneshot`, which systemd starts
   with no time limit, so nothing cuts the wait.
4. Every look applies the staleness rules again. A dead owner pid frees the
   lock at once, so an owner that dies during the wait frees it at the next
   look; so does this run's own pid in a lock it has not taken, left by an
   earlier process with the same pid. The two hour rule changed after
   review: it frees a lock only when its pid is alive but no A5N driver
   (`ps -ww -p <pid> -o command=` names none of the three scripts: another
   program got a dead owner's pid) or when the lock holds no pid (older
   versions). A live driver keeps its lock however old. A suspend of more
   than two hours, or a raw file copy stuck for an hour per project, stops
   the touches but not the run, and with a job waiting behind it the review
   reproduced the damage: the waiter took the lock within a look, stashed
   the running unit's half page with a "killed run" notification, and ran
   next to it. The user chose this rule knowing its cost: a driver that
   truly hangs keeps the lock, and the jobs behind it wait and skip (lint
   and digest with a notification). Every network call and the desktop
   notification are bounded (item 10) and the workers have a watchdog, so a
   hang is not expected.
5. Removing a lock is a look and then a remove, and two waiters that
   looked at a stale lock in the same instant both removed it: the second
   removed the lock the first had just written, and both ran. Every remove
   therefore happens under a second lock, `zsystem flock` on
   `.a5n-logs/.lock-guard`, held by a subshell for milliseconds, after a
   look taken under it: the takeover of a stale lock, and the owner's own
   remove at exit, so a waiter cannot see the lock vanish between its look
   and its remove. The kernel drops the second lock when the process
   holding it exits, so it cannot go stale. Without `zsh/system` or a
   writable guard file the remove goes on without it, as before the guard
   existed, with a warning in the log: a stale lock that stays for good
   would swallow every later run. The whole lock did not move to `flock`:
   the staleness rules read the pid in the file, and a process drops its
   `fcntl` lock when it closes any descriptor of the file, a trap any later
   redirection could spring.
6. The drivers set their traps before the wait, so a stop during it leaves
   as a stop (143, 130 or 129). The exit trap removes the lock only when this
   run took it and the file still holds this run's pid: a run stopped while
   it waited, or whose lock was taken over or removed meanwhile, leaves the
   lock alone. The touches use `touch -c`, so such a run does not bring the
   lock back as an empty file.
7. `CLOBBER_EMPTY` (zsh 5.9, off unless a `.zshenv` sets it) would let `>`
   reuse an empty file, and a lock is empty for an instant after another
   run creates it; the create turns it off.
8. When the wait runs out, the job does what it did before: the ingest logs
   the skip, the lint and the digest notify. A run started by hand on a
   terminal prints one line to stderr when it starts to wait and one when
   it gives up; Ctrl-C stops it.

Three hardening changes followed the second review, the same day:

9. The drivers reset every zsh option (`emulate -R zsh`) before their first
   command. zsh runs the user's `.zshenv` before any script, and an option
   set there reached the lock code. With `KSH_GLOB` the running driver
   check matched no command line, so a waiting job took a live run's lock
   once it was two hours old. With `SH_GLOB` `lib/common.sh` and
   `lib/sync.sh` did not parse: no lock function existed, and on a scratch
   vault every ingest logged a lock that nobody held and skipped, the lint
   and the digest with a notification that gave the same wrong reason.
   `emulate -L zsh` inside the lock functions cannot help there, since the
   parse fails before any function runs. Plain `emulate zsh` resets only
   the options emulation cares about and leaves `FORCE_FLOAT`, which made
   the lock's age a float and its comparison an error, and `CLOBBER_EMPTY`
   (item 7); `-R` resets them all. Variables, `PATH` among them, stay as
   the `.zshenv` set them. The create keeps its own `CLOBBER_EMPTY` line
   for a caller that sources the library on its own, as the tests do. The
   cost: `zsh -x` traces a driver up to that line only.
10. The macOS notification gets the bound notify-send has on Linux, ten
    seconds, through the watchdog the network commands use. That watchdog,
    `a5n_bounded`, moved from `lib/sync.sh` to `lib/common.sh`, which
    `lib/sync.sh` requires already. No hang of osascript was ever seen, but
    it was the one call a macOS run made with no bound, and a run that
    hangs keeps its lock for good (item 4).
11. A job that finds the unit flag of a driver that still runs stops
    instead of stashing the unit; see "Interrupted units".

The wait for the remote lock (ingest step 6) got the same second look at
the vault that the wait for the remote got: after the lock is taken and
before the fetch and rebase, a git operation in progress or another branch
stops the run untouched, and hand edits get a manual changes commit of
their own. The tests showed what happened without it: a hand edit made git
refuse the rebase and was reported as a conflict, a rebase started by hand
was aborted by A5N's own, and another branch was rebased, processed and
pushed to the sync branch. The ingest's notification then says "layer 2
skipped", since its capture has already run and gone out. The hand edit's
commit goes out with the next push: the first unit's, or the next run's.

### Daily ingest

1. Start as above.
2. Layer 1 capture and its commit, as today. Offline and blocked runs still
   do this: the transcript deletion clock is the only deadline in the system.
3. Online only: raw upload for every namespace with a local `raw/`, then
   push. Upload comes first so a page never reaches the other machine before
   the raw file it cites. A conflict here marks the run blocked: these
   commits are manual edits and skip lines, not units, and cannot be dropped.
   A push that ends offline or rejected turns the run offline: the commits
   stay local, layer 2 is skipped, and the day rule counts the failure.
4. Empty queue: the run ends. The lock is never waited for.
5. Offline or blocked: layer 2 is skipped, logged, exit 0.
6. No lock yet: wait, polling every 5 minutes for at most 1 hour, touching
   the local lock at every poll. On success look at the vault again (added
   2026-09-29, see "The local lock"), then fetch and rebase again (the other
   machine may have processed units meanwhile) and recompute the queue. On
   timeout log who holds the lock since when, skip layer 2, exit 0.
7. Per unit: remember `HEAD` as the unit base, write the unit flag, run the
   worker and the verification as today, commit, remove the flag (also after
   a final rollback), then push with the unit rules below.
8. After every unit: touch the local lock (as today) and refresh the remote
   lock. A lost lock stops layer 2.

### Push rules

1. Nothing ahead of `<remote>/<branch>`: success.
2. `git push <remote> HEAD:refs/heads/<branch>`. Accepted: success.
3. Refused: fetch. Fetch fails: offline.
4. Rebase onto the fetched branch. Conflict: abort, report conflict.
5. Push again. Accepted: success. Refused: report rejected.

What a unit does with each result:

* success: continue.
* conflict: reset hard to the unit base and clean (the unit commit is
  dropped; its raw file has no trace, so the unit stays queued), then rebase
  onto the remote, which is a fast forward. If that rebase conflicts too,
  the run is blocked, layer 2 stops and a notification fires.
* offline or rejected: the commit stays local, layer 2 stops, the next run
  pushes it. A valid unit is never thrown away for a network problem.

### Weekly lint

Everything the lint does needs the lock. Offline: notify "lint skipped",
exit 0. Blocked: exit 0. Lock wait timeout: notify "lint skipped", as the
lint already notifies when the wait for the local lock runs out. A vault
that changed under the lock wait: exit 0 after the vault check's own
notification, with no second one. The mechanical repair commit and each
project report follow the unit rules.

### Monthly digest

No remote lock and no raw download: the digest only writes `digests/`, and
only one machine runs it. It fetches and rebases first so the other
machine's commits are counted. Offline: notify "digest skipped", exit 0,
because a digest of partial history would be wrong. Its commit follows the
unit rules; a dropped digest commit notifies.

### End of run

The EXIT trap releases the remote lock if this run holds it. zsh skips
the EXIT trap when a signal it does not trap ends it, and a service
manager stops a run with TERM, so the ingest and the lint trap TERM, INT
and HUP, and since the wait for the remote the digest too: the trap stops
the worker first where there is one (started with `&` it ignores
INT, and a kill of the driver alone never reaches it), then exits
through the EXIT trap. Found when the first real run was stopped.
Anything started while a signal trap runs inherits that signal blocked,
so the network watchdog ends its sleep and, after a 5 second grace, the
command with KILL; otherwise a leftover sleep kept `systemctl stop`
waiting 90 seconds. The systemd service treats 143, 130 and 129 as
success: a stop is not a failure.

## The remote lock

`refs/a5n/lock` on the sync remote. It points at a commit with an empty tree
and no parent whose message reads `a5n lock: host=<host> pid=<pid>
job=<ingest|lint> at=<local time>`. Its age comes from the commit's committer
timestamp.

* Take: `git push --force-with-lease=refs/a5n/lock: <remote>
  <commit>:refs/a5n/lock`. The empty expectation means "must not exist", and
  the server checks and writes in one step, so of two simultaneous attempts
  exactly one wins.
* Refused: `ls-remote`. Unreachable: not taken. No lock there: retry the
  create once; refused again with no lock present means the remote does not
  accept custom refs, which notifies. A lock there: fetch it into
  `refs/a5n/seen-lock` and read it.
* Stale: older than 2 hours, or owned by this host with a pid that is no
  longer alive (the local lock's dead owner rule; a crashed run does not
  make this machine's next run wait 2 hours). A stale lock is taken over
  with the lease set to that lock's commit, so two machines cannot both take
  it over. The previous owner is logged.
* Refresh, after every unit: a new lock commit, lease on our commit. Without
  it a normal run longer than 2 hours would look stale to the other machine.
  Refused: still ours means a network blip, keep going; anyone else's or
  gone means lost: notify, stop layer 2; unreachable: stop layer 2.
* Release: delete with the lease on our commit, so a run that lost its lock
  can never delete the new owner's. A failed release is logged; the lock
  then expires after 2 hours, or at once for this host's next run.
* Busy: the holder (host, job, since when) is logged when layer 2 is
  skipped.

## Failure visibility

* Offline, once the wait for the remote is over: a WARNING log line,
  capture continues, pushes wait for the next run.
* The day rule: `.a5n-logs/.sync-failing-since` holds the time of the first
  failed sync since the last success. It is created at a failure, removed at
  a success, and when a failure finds it older than 24 hours, a notification
  fires. Success means the local branch equals the remote branch after a
  fetch or a push. Failure means an unreachable remote, a start rebase
  conflict, or a push that ended offline, rejected or in conflict.
* Immediate notifications: blocked runs, raw copy failures, a lost lock, a
  remote that refuses the lock ref, an interrupted unit moved to the stash,
  a unit whose driver still runs, lint or digest skipped.
* Timeouts: every git network command is bounded to 120 seconds and every
  rclone call to 1 hour, with the same watchdog pattern the unit worker
  uses (macOS has no `timeout(1)`). Without a bound, one hung push would hold
  the local lock forever and every later run would skip in silence.
  `GIT_TERMINAL_PROMPT=0` makes a missing credential fail instead of waiting
  for input. The desktop notification gets 10 seconds on both systems:
  notify-send through `timeout(1)`, osascript through the same watchdog.
* Test knobs, environment only: `A5N_SYNC_WAIT` (3600), `A5N_SYNC_POLL`
  (300), `A5N_SYNC_RETRY_DELAY` (20, also the pace of the wait for the
  remote), for the local lock (`lib/common.sh`) `A5N_LOCK_WAIT` (7200)
  and `A5N_LOCK_POLL` (10), and `A5N_OSASCRIPT` (`/usr/bin/osascript`),
  which no PATH shim can stand in for.

## Interrupted units, with sync on or off

A driver killed in the middle of a unit left half written pages behind, and
the next run's "manual changes" commit swept them into history (and, with
sync on, would push them to the other machine).

* `.a5n-logs/.unit-in-progress` is written before a unit's first change (an
  ingest unit, the lint's mechanical step, a lint project, the digest) and
  removed right after that unit's commit or rollback. It holds the job, the
  unit, the pid and the start time.
* At start, after the sync recovery: flag present and tree dirty: `git stash
  push -u -m "a5n: interrupted unit (<flag>)"`, a log line and a
  notification that says how to look (`git stash list`); flag present and
  tree clean: a log line. The flag is then removed. If the stash fails the
  run notifies and exits: those changes are never committed as manual edits.
* Added with the lock hardening (2026-09-29): before any of that, the pid in
  the flag is checked. When `ps` shows an A5N driver with that pid, and it
  is not this run's own, the unit is still running: its driver lost the
  lock, removed by hand, or taken from a driver another user runs, whose pid
  `kill -0` cannot signal and the lock rule counts as dead (`ps` still sees
  it). The stash took the half page from under that unit, and this run
  worked next to it. Now the run leaves the tree and the flag alone, writes
  that pid into the lock under the guard, so the driver's touches and its
  exit find the lock again and later jobs wait for it, notifies ("A5N run
  pid N is still inside a unit (ingest alpha/1a2b3c4d) after losing its
  lock; this run stopped without touching the vault and gave the lock
  back") and exits 0, the way a skipped run does. Ingest, lint and digest
  behave alike. A flag whose pid is dead, is this run's own (an earlier
  process had it) or runs no A5N driver (reused) is a killed run's unit, as
  before.

## setup.sh

* `.gitkeep` files are created only when missing. `touch` refreshed their
  mtime on every run, and `rclone copy --immutable` reports a file whose
  mtime changed as modified (exit code 6 on a real vault).
* Sync on, after the git step and before scheduling: the git remote must
  exist and the vault must be on `sync.branch` (every run would skip,
  capture included, on any other branch); with `raw_remote` set, rclone must
  be installed and, unless the value is an absolute path or an on the fly
  `:backend:` path, the remote name before the first colon must be in
  `rclone listremotes`. Any miss stops setup with the command that fixes it,
  before a timer is touched. A `raw_remote` while `raw/` is still tracked by
  git prints a warning (raw files would travel twice).
* Sync on: `**/log.md merge=union` is appended to the vault's
  `info/attributes` (path from `git rev-parse --git-path`) unless present.
  Machine local on purpose: the vault itself carries no `.gitattributes`.
* Scheduling: a job set to `off` is not installed; an installed one is
  removed (launchd: bootout and plist removed; systemd: `disable --now`, unit
  files removed, `daemon-reload`). The crontab hint lists only jobs that are
  not off.

## Other fixes in this change

* The weekly lint prompt no longer hardcodes `state:`. It tells the worker
  that the bug state field and its closed list are defined in the vault's
  CLAUDE.md and to read them there; the default schema's `state: open |
  pending | fixed | closed` is the example. A vault whose schema names the
  field differently is audited against its own list.
* Desktop notifications on Linux through `notify-send`, with a 10 second
  timeout (with nobody logged in there may be a bus but no notification
  daemon) and a fallback to `/run/user/<uid>/bus` when the bus address is
  not in the environment. Checked for real once with `systemd-run --user`,
  which gives a command the same environment a timer's service gets.

## Testing

The repository has no test suite; its documented practice is a scratch
config plus the `A5N_*` knobs. `tests/sync-e2e.sh` turns that into a
repeatable run. Linux only for now. Everything lives in a temporary
directory: a bare repository stands in for the git remote, an rclone config
with a `local` type remote stands in for cloud storage, two machines each get
a config, a vault clone and a transcript folder, and `HOME` and
`XDG_CONFIG_HOME` point inside the temporary directory. `tests/fake-runner.sh`
replaces the model: the tests pass `A5N_PROMPT_FILE` and
`A5N_LINT_PROMPT_FILE` templates that carry only `key=value` lines, and the
fake runner writes a verified page, a log line or a lint report from them.
Shims record calls to `systemctl`, `loginctl`, `launchctl` and
`notify-send`, and, where a scenario counts network calls, to `git` and
`rclone`. No scenario touches a real vault, timer or remote.

Scenarios:

1. Two machines in turn: one runs and pushes, the other pulls its pages and
   raw files and processes its own, the first runs again. Every session has
   exactly one page, both vaults and the storage hold every raw file, no
   conflict markers, no lock ref left behind.
2. Lock race: twenty rounds of simultaneous takes from both clones, exactly
   one winner each round.
3. Busy lock: the other machine holds a fresh lock. The run captures,
   uploads, pushes its capture commit, waits, gives up and logs the holder.
4. Wait then take: while the run waits, the other machine processes one of
   its queued sessions and releases. The run takes the lock, pulls,
   recomputes the queue and processes only the rest.
5. Stale lock (committer date 3 hours back) and same host dead pid lock are
   both taken over.
6. Offline: the bare repository is moved away. Capture and the local commit
   happen, no unit runs, rclone is never called after the failed fetch. With
   an old `.sync-failing-since` a notification fires. Back online, the next
   run pushes the waiting commits and processes the queue.
7. `log.md` union: both machines append to the same `log.md`; the start
   rebase and a refused unit push both merge without conflict and keep both
   lines.
8. Interrupted unit: the driver is killed while the fake worker sleeps after
   writing half a page. The next run stashes it, makes no manual changes
   commit with it, notifies, and processes the unit.
9. Unit push conflict: while a unit runs, the other machine pushes a
   conflicting edit to the same line of the root `index.md`. The unit commit
   is dropped, the unit stays queued, the next run processes it.
10. Lint and digest with sync: lint takes and releases the lock and pushes
    each report; digest takes no lock and pushes; both notify and skip when
    offline.
11. `setup.sh`: missing remote and unknown rclone remote stop it before any
    timer call; a rerun does not duplicate the attributes line or change
    `.gitkeep` mtimes; `lint = off` removes an installed lint timer.
12. Sync off is unchanged: with `A5N_BASELINE_REF=<ref>` the same fixtures
    run through `git archive <ref>` and through the working tree, sync off;
    ingest, lint and digest must produce the same `git log --format='%s
    %T'` (subject and tree), and the recorders must show no network call.
    The acceptance run uses 53af4e9, the commit before this change.
13. Added after review: `setup.sh` stops on a vault that is not on
    `sync.branch`; a `.DS_Store` rewritten inside `raw/` raises no alarm
    and never travels; a rebase conflict at the start of a run blocks it
    (capture still happens, no worker, no lock, a notification with the
    path); a run stopped mid unit by TERM to its group, INT to its group
    or TERM to the driver alone leaves no worker behind, releases both
    locks and keeps the unit flag for the next run.
14. Added with the wait for the remote (2026-09-29). The loginctl shim reads
    the login state from a file each test world owns. A run that starts
    while nobody is logged in waits for the login, asks the remote nothing
    meanwhile, then processes its unit and pushes; a logged in run keeps
    trying until a late remote answers; lint and digest run instead of
    being skipped; the last attempt at the end of the wait reaches a remote
    that came back while nobody logged in; a remote that never comes back
    ends the run offline exactly as before, within `offline_after` plus one
    round; an ingest, a lint or a digest stopped during the wait, by TERM
    to its group or to the driver, ends at once, leaves no process and no
    local lock, and captures nothing. After review: a hand edit made during
    the wait gets its own commit and the run goes on (online and offline);
    a rebase started by hand during the wait, or another branch checked
    out, stops the run untouched. The older scenarios run with
    `offline_after = 0`.
15. Added with the local lock (2026-09-29), sync off unless noted. The fake
    runner writes a start and an end line per worker, so a test sees two
    workers running in one vault at once. An ingest and a lint started in
    the same instant both run, one after the other, and exactly one of them
    waited; an ingest that arrives while a lint runs waits and then runs; a
    holder that never finishes makes each job wait out the bound and then
    act as before (the ingest logs, lint and digest notify), a run on a
    terminal (`script` gives it one) says it waits, and the holder's lock
    stays; a job stopped during the wait, by TERM or INT to its group or
    TERM to the driver, ends at once with the status of a stop and leaves
    the holder's lock alone; a dead owner, and a lock three hours old whose
    pid is no A5N run, are still taken over at once; an owner that dies
    during the wait frees the lock at the next look; three waiters released
    in the same instant, thirty rounds against a dead owner, an old lock and
    no lock, give exactly one winner each round. Without the kernel lock
    that round count found two winners, without `O_EXCL` three. With sync
    on: a hand edit, a rebase started by hand or another branch during the
    wait for the remote lock, for the ingest, and for the lint one
    notification only. After review: a running ingest whose lock is three
    hours old (what a suspend leaves) keeps it, and the lint behind it
    waits instead of stashing its unit; a lock with the run's own pid is
    taken; an empty lock is not overwritten with `CLOBBER_EMPTY` set; a run
    removes only a lock that still holds its pid, and does not bring back a
    removed one as an empty file; without the guard a stale lock is still
    taken over, with a warning. Each of these was also checked against a
    copy with its fix removed.
16. Added with the lock hardening (2026-09-29), sync off. The suite unsets
    `ZDOTDIR`, so no `.zshenv` but a scenario's own reaches a driver.
    macOS: `uname` answers `Darwin` for one scenario and `A5N_OSASCRIPT`
    points at a fake that hangs and ignores TERM; the ingest that notifies
    ends within 20 seconds (10, then 5 of grace), the fake is killed, and
    the lock is gone. zsh options: with a `.zshenv` of the scenario's own
    that sets `KSH_GLOB`, then `SH_GLOB`, the drivers parse, and a lint
    waits for a live process whose command line names a driver although
    its lock is three hours old, and leaves that lock alone; ingests with
    `KSH_GLOB`, `SH_GLOB` or `FORCE_FLOAT` set take over a lock three hours
    old whose pid is no A5N run and process their sessions, and a digest
    with `SH_GLOB` set is written (`SH_GLOB` alone: with `KSH_GLOB` next to
    it those patterns parse again, and the check missed the digest's
    reset). A running ingest whose lock was removed by hand: a lint started
    next to it exits 0, stashes nothing, keeps the flag, notifies, gives the
    lock back and runs no worker, and the ingest finishes its unit and
    removes the lock. A flag whose pid runs no A5N driver, or holds the
    run's own pid, is stashed as before. Each check was run against a copy
    with its fix removed, and failed there: the bound, the reset in each
    driver, `-R` itself, the live unit check, its own pid and A5N rules, and
    the lock given back.

Plus the standard checks: `py_compile`, `zsh -n` on every shell file,
`config.py --check` on the test configs, and config validation cases.

## Documentation

* `README.md` and `README.tr.md`: a "Two machines, one vault" section (what
  one run does, how to set it up, the lock, what happens offline and on a
  conflict, `off` for lint and digest on the second machine) and two bullets
  in "How it holds together": the remote lock and the interrupted unit
  stash.
* `config.example.ini`: the `[sync]` section and the `off` value.
* `AGENTS.md`: `scripts/lib/` and `tests/` in the layout, the test script in
  "Testing a change". `CONTRIBUTING.md`: the same testing line.

## Rolling out on an existing vault

1. Check once that the remote accepts `refs/a5n/*`: push a throwaway ref,
   read it back, delete it.
2. First machine: set `[sync]`, run `setup.sh`, run the ingest by hand and
   read its log.
3. Second machine: update A5N, bring the vault clone up to date, copy the raw
   files once if `raw_remote` is used, set `[sync]` and `[schedule]` (`lint =
   off`, `digest = off`, an ingest time different from the first machine's),
   run `setup.sh`, run the ingest by hand.

The user specific version of this plan (machine names, paths) is kept out of
this repository, like any other vault data.

## Known limits

* A credential helper that reads a desktop keyring cannot work before login.
  A run that starts before login waits up to `offline_after` for one. If
  nobody logs in by then it runs offline as before (capture happens, layer 2
  waits for the next run, lint and digest are skipped), and its
  notification may reach nobody: a desktop without a session may have no
  notification daemon.
* A job waits for the local lock at most two hours. Three runs a timer
  starts at one boot run one after another, and when a long ingest (up to
  95 minutes observed) and a lint (about 30) come before the third, the
  third waits past the two hours and is skipped as before: a lint or a
  digest with a notification, an ingest until the next day. A run waiting
  for the remote, or for the remote lock, holds the local lock meanwhile,
  so the jobs behind it wait that long too.
* A live A5N run keeps the local lock however old it is. One that truly
  hangs would keep it for good: the jobs behind it wait two hours and skip,
  lint and digest with a notification, the ingest in its log only, so on a
  machine that runs only the ingest (a second machine with lint and digest
  off) nothing says so. The scheduler never starts a second instance of a
  job that still runs, so a stuck ingest held the next ones back before
  this change too. Every network call and the desktop notification are
  bounded and the workers have a watchdog. The check reads the driver's
  name from its command line, so a driver started under another name (a
  symlink) falls back to the two hour rule, and a job that then takes its
  lock does not recognize its running unit either: the unit goes to the
  stash as a killed run's.
* A driver another user runs (sudo) looks dead to the lock rule, whose
  `kill -0` cannot signal it. A job that takes its lock inside one of its
  units stops and gives the lock back; one that takes it between two units
  runs next to it.
* Two machines scheduled at the same minute make one of them wait. Runs of
  34 to 83 minutes were observed on a real vault, so the waiting machine can
  miss its layer 2 for the day. Stagger the schedules.
* A remote that refuses custom refs cannot hold the lock; the run notifies.
* With sync turned off, an A5N rebase that was interrupted while sync was on
  is not recovered: that recovery is part of sync, and sync off runs no sync
  code at all.
* Clock skew between machines shifts the 2 hour staleness by the same
  amount.
