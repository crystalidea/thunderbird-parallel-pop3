# parallel-pop3

Makes Thunderbird check POP3 accounts concurrently instead of one after
another. Accounts that download into the same folder — a global inbox, or
several accounts deferred to the same account — still run one at a time.

Built for **Thunderbird 154.0**. Off by default.

## Why

Thunderbird checks every POP3 account strictly one at a time. With ten
accounts on slow servers a full check takes minutes, and the account you are
waiting for may well be last.

This is deliberate, and recent. [Bug 1847137][b1847137] made POP3 serial in
Thunderbird 128 to cure a hang that hit users with several accounts on the
same check interval. It worked, but it traded a hang for a stall:
[bug 1943854][b1943854] tracks the result and is still open, marked `perf`
and `regression`.

The serialisation is one process-wide mutex — two `static` fields shared by
every `Pop3IncomingServer` instance, so only one POP3 connection exists at a
time across the whole application. That is far broader than the problem
requires. The actual hazard is two accounts writing into the *same* mailbox
file, which is why [bug 707933][b707933] existed in the first place.

This patch replaces the single global lock with:

- one lock per **download destination**, so accounts with separate inboxes run
  concurrently while accounts sharing an inbox stay serialised, and
- one lock per **server**, so a single account can never have two clients
  running at once whatever their destinations.

Locks are a promise chain, taken in sorted key order, so ordering is total and
deadlock is impossible.

[b1847137]: https://bugzilla.mozilla.org/show_bug.cgi?id=1847137
[b1943854]: https://bugzilla.mozilla.org/show_bug.cgi?id=1943854
[b707933]: https://bugzilla.mozilla.org/show_bug.cgi?id=707933
[b2020627]: https://bugzilla.mozilla.org/show_bug.cgi?id=2020627

## Enabling it

Nothing changes until you ask for it. Per launch:

```
thunderbird -parallel-pop3
```

The flag is consumed at `command-line-startup` and sets the pref on the
default branch, so it lasts for that session only and never reaches
`prefs.js`. To turn it on permanently, set this in the Config Editor instead:

```
mail.pop3.parallel_accounts = true
```

A user-set value of that pref overrides the flag, so do not set it to `false`
by hand if you plan to use `-parallel-pop3`.

## Installing

### Windows

Two batch files with the paths already filled in, for double-clicking:

| File | What it does |
| --- | --- |
| `patch-parallel-pop3-dry-run.bat` | Verifies everything, writes nothing |
| `patch-parallel-pop3.bat` | Asks for confirmation, then patches |

Both accept an installation and a profile path as optional arguments:

```
patch-parallel-pop3.bat "D:\Thunderbird" "G:\Profile"
```

### Any platform

```
perl patch-parallel-pop3.pl --install DIR --profile DIR [--dry-run]
```

```bash
# Linux
perl patch-parallel-pop3.pl \
  --install /usr/lib/thunderbird \
  --profile ~/.thunderbird/xxxxxxxx.default-release

# macOS - point at the bundle, the script finds Contents/Resources itself
perl patch-parallel-pop3.pl \
  --install /Applications/Thunderbird.app \
  --profile ~/Library/Thunderbird/Profiles/xxxxxxxx.default-release
```

| Option | Meaning |
| --- | --- |
| `--install DIR` | Thunderbird installation directory |
| `--profile DIR` | Profile whose `startupCache` gets deleted |
| `--payload DIR` | Where `manifest.json` and `payload/` live. Defaults to the script's own directory |
| `--dry-run` | Verify and report, write nothing |
| `--restore` | Put the backed up `omni.ja` back |
| `--force` | Allow a version mismatch. Does **not** relax the SHA-256 checks |
| `--help` | Usage |

Requires `Archive::Zip`. Everything else is core Perl. The script prints the
right install command for your platform if it is missing.

Thunderbird must be closed; the script checks and refuses otherwise.

### The profile argument is not optional in practice

`--profile` is used for exactly one thing: deleting `<profile>/startupCache`.
Nothing else in the profile is read or touched.

That directory holds precompiled bytecode for the very modules being replaced.
Leave it in place and Thunderbird keeps running the old code — silently, with
no error, looking exactly like the patch did not work. Starting once with
`-purgecaches` achieves the same thing, but the script does not rely on you
remembering that.

## What it changes

Everything lives inside `omni.ja`, a plain ZIP archive in the installation
root holding the application's interpreted parts. No compiled code is
involved, which is why this can be applied to an official build.

```
modules/Pop3IncomingServer.sys.mjs   the lock itself
modules/Pop3Service.sys.mjs          passes the destination folder in
modules/Pop3Channel.sys.mjs          same, for single-message body fetches
modules/MailGlue.sys.mjs             the -parallel-pop3 flag
```

Nothing else in the installation is modified. `omni.ja` is copied to
`omni.ja.bak-<version>-<buildid>` before the first write, and an existing
backup is never overwritten.

`payload/*.orig` are the stock files this was built against, kept so you can
diff them against `payload/*.new` and see exactly what changed.

## Safety model

A version check alone would be useless here — the source tree is always
Nightly and any release is older, so it would fail every time. It is kept only
as a first, informational gate, and `--force` skips it.

The real check is per file. Each of the four entries is compared by SHA-256
against the exact bytes the patch was built from, recorded in
`manifest.json`. Three outcomes:

| Entry matches | Result |
| --- | --- |
| `origSha` | Stock, will be patched |
| `newSha` | Already patched, left alone |
| Neither | Abort before anything is written |

`--force` never relaxes this. Verification of all four entries completes
before the backup is taken, so an abort leaves the installation untouched.
After writing, every entry is re-read and re-hashed.

Tested against a throwaway copy of a real installation: dry run, apply,
re-apply (idempotent), version mismatch, restore, and a deliberately tampered
entry — which aborted with the backup still byte-identical to stock.

## Known limitation

Filter Move and Copy actions are not covered by the lock.

**There is exactly one risky case: a message filter whose target folder is
another POP3 account's inbox.** Check your filters for that. If none of them
point at another account's inbox — and most setups have no such filter — this
limitation does not apply to you at all.

Affected:

- Account B has a filter moving or copying mail into account A's inbox, and
  A happens to be downloading at that moment.

Not affected:

- Filters sorting mail into their own account's subfolders.
- Filters from several accounts targeting one shared third folder, as long as
  no POP3 account downloads directly into it. There the semaphore is taken and
  released inside a single synchronous call, so there is no window to collide
  in.
- Everything, if you leave `mail.pop3.parallel_accounts` off.

Why it happens: `nsPop3Sink` acquires the download destination's semaphore and
holds it for the whole session, while a filter needs that same semaphore on
its own target folder — which this patch's lock key knows nothing about. The
losing filter fails with `NS_MSG_FOLDER_BUSY` and is logged as
`filter-failure-move-failed`. Under timed biff it is silent, because
`nsMsgBiffManager` passes a null `msgWindow` and the alert is suppressed.

No mail is lost either way. The message stays in the inbox it arrived in
instead of being filed. Before Thunderbird 128 this was possible too, since
POP3 accounts ran in parallel then as well; it became impossible only while
the single global lock was in force.

Fixing it properly means either locking every enabled InboxRule target as
well, or routing `NS_MSG_FOLDER_BUSY` through the existing move coalescer in
`nsParseMailbox.cpp` and replaying it afterwards. Both are well beyond a
JS-only patch.

## Caveats

**Updates revert this.** Any Thunderbird update overwrites `omni.ja`. A
partial update will also fail its CRC check against the modified file and fall
back to downloading a full package, roughly 80 MB instead of 5. Re-run the
script after each update.

**macOS code signing.** Editing `omni.ja` invalidates the bundle signature. If
Thunderbird then refuses to start, re-sign it ad hoc:

```bash
codesign --force --deep --sign - /Applications/Thunderbird.app
```

**Startup is marginally slower.** Mozilla builds `omni.ja` with a preload
header and a specific entry order that a standard rewrite cannot reproduce.
The archive stays valid; only the preload optimisation is lost.

## Files

```
patch-parallel-pop3.pl             the patcher
patch-parallel-pop3.bat            Windows, with confirmation
patch-parallel-pop3-dry-run.bat    Windows, verify only
manifest.json                      expected and patched SHA-256 for all four entries
payload/*.orig                     stock modules this was built against
payload/*.new                      patched modules
```

## Rebuilding for another Thunderbird version

The payload is pinned to one build. To retarget it:

1. Extract the four modules from the new installation's `omni.ja` into
   `payload/*.orig`.
2. Diff each against the same file in a comm-central checkout. Where a module
   is byte-identical to the tree, the patched working copy drops straight in.
   Where it has diverged, apply the change by hand to the installed file
   instead. Which modules fall in which group changes from release to release,
   so check every time: going 153.0.3 to 154.0, `Pop3Channel.sys.mjs` caught up
   with the tree and became a straight copy, while `MailGlue.sys.mjs` stayed
   behind and still needed grafting.
3. Apply the changes to produce `payload/*.new`.
4. Regenerate `manifest.json` with fresh SHA-256 values and the new
   `targetVersion`.

## License

[MPL-2.0](LICENSE).

`payload/*.orig` and `payload/*.new` are Mozilla source files, modified in the
case of `*.new`. MPL 2.0 is per-file copyleft, so those stay under it and keep
their original license headers. The patcher and the batch files are offered
under the same license for simplicity.

Note for contributors: `.gitattributes` marks `payload/**` as binary. Those
files must reach `omni.ja` byte for byte, and an end-of-line conversion on
checkout would break the SHA-256 verification.

## Provenance

Built from comm-central `156.0a1` at `48d14750199`, targeting Thunderbird
`154.0` (build `20260818021538`). Earlier revisions targeted 153.0.3; that
payload is in the git history.

The POP3 client stack is identical between the two — `Pop3Client.sys.mjs` is
byte-for-byte the same, including the watchdog timer from
[bug 2020627][b2020627] that fixed POP3 deadlocking on silent servers. That
bug is worth knowing about: it held the same global lock forever, and its
existence is part of why serial checking looked worse than it was.

Verified against the source tree with the full `mailnews/local` and
`mailnews/base` xpcshell suites — 137 passing, plus a new
`test_pop3ParallelDownload.js` covering three cases: distinct destinations run
concurrently, a shared inbox stays serialised, and the pref off serialises
everything.
