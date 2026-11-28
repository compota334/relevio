# The encrypted conversation archive

Part of the [relevio](../README.md) documentation.

Claude Code keeps each conversation as a plain file in `~/.claude/projects/`,
and files can still disappear: its own cleanup, a bug, a deleted folder.
relevio keeps an **encrypted copy of every conversation** of this machine in
`~/.relevio/` (or `$RELEVIO_HOME`), outside every repository, and can put a
lost one back so `claude --resume` opens it again.

- **When:** each session is archived as it ends (the `SessionEnd` hook), and
  every session start sweeps its repository in the background, including the
  folders of its worktrees, so a session whose end was missed is caught at
  the next start. Both run detached and never slow a session down.
- **How:** each session (its transcript plus its `subagents/` and
  `tool-results/`) is packed, compressed and encrypted with
  [age](https://age-encryption.org) to two keys. Measured on real
  conversations: 164 MB became 47 MB.
- **Two keys, no server:**
  1. a **main key**, protected by your **passphrase** (your everyday key):
     what `restore` asks for. You choose it at setup; if you leave it empty,
     age invents one made of words joined by dashes, and those words are the
     passphrase;
  2. a **recovery key** (your emergency key), one long code that starts with
     `AGE-SECRET-KEY-1` (age's marker for a secret key), shown once at setup,
     that only you keep (a password manager or paper): for when the
     passphrase is lost.

  Every screen that asks for a key says which of the two it wants, what that
  key looks like, and how to paste it (Linux Ctrl+Shift+V, macOS Cmd+V,
  Windows Terminal Ctrl+V).

  Archiving uses only their public halves, so the hooks never hold a secret.
  **If you lose both the passphrase and the recovery key, the archive is
  gone: nobody, relevio included, can open it.**
- **What changes are kept:** a conversation that only grew replaces its copy;
  one that was rewritten keeps the previous copy as an older generation,
  never deleted automatically. A session you delete on purpose in the Claude
  desktop app is not archived; a copy archived earlier is kept and marked
  (`status` shows it), and `forget` removes it for good.

## Commands

All in `.claude/scripts/relevio-archive.sh` (in a plugin install, the plugin's
`scripts/`). The ones that ask for a secret run **only in a real terminal**,
and the secret is always typed by you, there: a secret typed in a chat would
be stored in a plaintext transcript. The agent may open your terminal with
the command ready, so your part is one paste and one Enter; it never reads
that terminal during `setup`, whose screen shows the keys.

| Command | What it does |
|---|---|
| `setup` | Creates the keys (your terminal: asks for the passphrase twice, shows the recovery key once and asks you to type it back). |
| `backfill` | Archives every conversation already on the machine, with progress. Checks the free disk space first. |
| `status` | Set up or not, on or off, the keys by prefix, the last run, what is archived, and Claude Code's `cleanupPeriodDays`. Exits 1 when something needs attention. |
| `list [query]` | What is archived, filtered by id prefix, folder or path. Reads the index only: decrypts nothing. |
| `restore <id>` | Puts a session back (your terminal). Checks every file against what was archived before moving anything, never creates a second copy of the id (that would break `--resume`), moves a different current copy aside instead of deleting it, and prints the exact `cd ... && claude --resume <id>` line. `--recovery` uses the recovery key; `--generation <file>` an older copy. |
| `keys check [--recovery]` | Proves a key opens the archive. |
| `keys passphrase` | Changes the passphrase. |
| `keys reset` | Lost the passphrase: with the recovery key, re-encrypts everything to a new main key, touching nothing old until every new copy is proven to open. |
| `keys rotate-recovery` | The recovery key leaked: shows a new one once, re-encrypts everything to the passphrase's key plus the new one (same safety as `reset`), and replaces the off-machine copy. The old recovery key then opens nothing. |
| `forget <id>` | Removes a session from the archive for good, and keeps it from being archived again. |
| `remote connect b2 <bucket>` / `s3 <bucket> <endpoint> <provider>` / `gdrive` | Connects a cloud account in one step: asks only the key (hidden, never on a command line), checks it, sets the copy and sends everything. |
| `remote set folder <path>` / `remote set rclone <remote:path>` | Sets the copy off this machine (see below). `remote status` shows it; `remote off` stops updating it. |
| `push` | Sends what is new to the copy. Runs by itself after every archiving run once a copy is set. |
| `verify` | Checks the copy: every bundle by the provider's own checksum, md5 or sha1 (nothing downloaded), a random sample downloaded and checked by sha256, and the catalog. |
| `pull folder <path>` / `pull rclone <remote:path>` | On a new computer: brings the whole archive back from the copy into an empty `~/.relevio` (your terminal: asks for a key). Interrupted, it resumes. |
| `stamp setup` / `status` / `now` / `backfill` / `off` | Timestamps (see below). |
| `proof <id>` | Builds the folder you hand someone to prove a conversation existed at a date. |
| `proof-check <folder>` | Checks a proof folder here, against two Bitcoin explorers. |
| `off` / `on` | Stops and resumes archiving. What is archived stays. |
| `guide` | The instructions for the agent: what it may run itself, what only you type, which key each step asks for, and how to walk you through it one step at a time. `/kickoff` and `/revisit` point the agent to it. |

`/revisit` uses it too: when `claude --resume` no longer finds a session, the
agent looks it up with `list`, reads `guide`, and has you run `restore`.

## A copy off this machine

Same disk, same failure: the archive alone does not survive a broken disk or
a stolen laptop. A copy elsewhere does, and **everything in it is encrypted,
names included**:

- bundles travel under opaque names (a hash of a random salt and the name),
  so the copy does not show session ids or project names;
- the index, the folder list and the upload records travel as one encrypted
  `catalog.age`, written last, so it never names a bundle that is not there;
- the main key travels locked by your passphrase; the recovery key never
  travels anywhere.

Two ways to send it, one code path:

1. **A synced folder**: any folder a sync client already mirrors (Google Drive
   for desktop, Dropbox, OneDrive, iCloud, Syncthing, a NAS mount).
   `remote set folder <path>`. relevio writes there; the client uploads.
2. **rclone**: talks to the provider itself (Google Drive, S3, B2, SFTP,
   WebDAV and about 70 more), which is the way on Linux, where Google has no
   Drive client. Connect it once in your terminal, for Google Drive with
   least privilege (rclone then sees only the files it created):

       rclone config create relevio-gdrive drive scope=drive.file

   then `remote set rclone relevio-gdrive:relevio`.

**For a team, use an S3-compatible bucket** (Backblaze B2, Cloudflare R2,
AWS S3, Wasabi, a MinIO server): it is what backup tools use (restic, kopia),
it has no per-app request limit like Google Drive's (rclone's shared Google
app gets rate-limited: measured 2026-11-25), and an access key limited to one
bucket is the least privilege there is. Create the bucket and a key for that
bucket only; then one command asks for the key (hidden), writes it into
rclone's own config, proves it works and sends everything:

    remote connect b2 <bucket>                          # Backblaze B2
    remote connect s3 <bucket> <https endpoint> <provider>  # R2, AWS, Wasabi, MinIO
    remote connect gdrive                               # Google Drive (browser login)

Your AI assistant runs all of this for you: it asks in a form where the copy
goes and the bucket name, and opens your terminal only where you paste the key.

Google Drive with rclone works, but for daily use give rclone its own Google
client id (rclone's docs: "Making your own client_id"); a native "Connect
Google Drive" for relevio is planned.

What can go wrong, and what happens:

| Case | What relevio does |
|---|---|
| no network, provider down | the archive keeps working; the copy waits and `status` says since when |
| login expired (rclone) | `status` shows the exact `rclone config reconnect` command |
| a bundle altered or deleted in the copy | `verify` names it; the next `push` sends it again |
| an older catalog put back in the copy | `verify` catches it; the next `push` writes the current one |
| an emptied or damaged local index | nothing is deleted from the copy: only `forget` removes from it |
| the computer is lost | `pull` on the new one, with the passphrase or `--recovery` |

Measured on Google Drive (rclone 1.60.1): a cut upload leaves nothing behind,
uploading the same name twice keeps one file, deletions go to Drive's trash,
and Drive reports each file's md5 itself, which is how `verify` checks every
bundle without downloading it. Backblaze B2 keeps a sha1 instead of an md5
(measured 2026-11-26): `remote set` asks the provider which checksum it keeps
and the copy is checked by that one from then on.

Who can write to the copy is a different question from who can read it:
age encrypts but does not sign, so anyone holding the public keys could make
a file your key opens. So `pull` checks every record it brings back field by
field and refuses links, and the key list is **sealed** with your keys
(`keys/recipients.mac`, written wherever you type a key): a key someone adds
to the copy is caught before anything is encrypted to it. Someone who can
write to your copy can still delete it or plant a fake conversation in it;
they cannot read yours. An archive set up before the seal existed gets it the
first time you run `keys check` and `keys check --recovery`.

What the copy still reveals: how many bundles there are and how big each is.
After `keys reset` or `keys rotate-recovery` the copy is replaced, but your
provider may keep old versions or a trash folder for a while: empty them if a
key leaked.

## Timestamps

`stamp setup` installs the [OpenTimestamps](https://opentimestamps.org)
client (pinned, in its own folder inside `~/.relevio`). From then on every
archived conversation gets a proof that it existed, byte for byte, **no later
than a Bitcoin block**, without trusting relevio, you, or this computer's
clock. It does **not** prove who wrote it, nor that what it says is true.

- What is stamped is a small leaf holding `sha256(salt + transcript)`, with a
  random salt per conversation. Only the hash of that leaf reaches the public
  calendar servers: nobody can read or even confirm a guessed conversation
  from it. The salts and proofs travel inside the encrypted catalog.
- Leaves go out in batches (one call for thousands): when the oldest has
  waited a day, when 10 000 wait, or on `stamp now`. Bitcoin confirms a batch
  a few hours later. With no calendar answering, the leaves stay queued and
  `status` says so; at least two calendars must answer.
- Conversations archived before stamping was on are stamped when it is turned
  on: their proof says "no later than that day", not their original date.
  Those whose transcript is no longer on the machine need `stamp backfill`
  (your terminal, a key).
- `proof <id>` builds a folder for whoever must check it: the conversation
  (in clear: read it for secrets before sharing), its salt, the leaf, the
  proof and a `VERIFY.txt` with the steps (one `sha256sum` line, then
  opentimestamps.org or `ots verify`). `proof-check <folder>` does those
  steps here, asking two block explorers; one answer that matches is enough,
  any mismatch fails it.

## What the agent is told

At session start, in the one notice slot after the settings notice: that the
archive is not set up (at most once a day, silenced by `off`), or that it is
failing (every session, with the reason), was interrupted, or has not
succeeded in a week, or that the copy off the machine is failing. The agent
is told never to run `setup` itself, and the script refuses without a
terminal anyway. `guide` tells it everything else: which commands it may run,
which only you type, and how to walk you through them.

## Security and limits

- Protects against losing conversations to Claude Code's cleanup or a
  deleted folder, and against a copy of `~/.relevio` leaking (a synced folder,
  a stolen backup): the bundles are encrypted to your keys.
- Does **not** protect against someone with your account on this machine: the
  conversations in `~/.claude` are plain files, and the archive's index
  (`index.tsv`: ids, folder names, paths and sizes, no content) is plain too.
  Full-disk encryption is still recommended. `status` lists the keys an
  archive is encrypted to, so a key added behind your back is visible.
- The archive refuses to live inside a git repository, behind a symbolic
  link, or in a folder you do not own.
- Without a copy off the machine (above), same disk, same failure.
- Not archived: Claude Code's file checkpoints (`file-history/`), and ZCode
  sessions (they are not transcript files).
- Whether the Claude desktop app runs the `SessionEnd` hook is not verified
  yet; its sessions are archived by the next session start's sweep either way.
