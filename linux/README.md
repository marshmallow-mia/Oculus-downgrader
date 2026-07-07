# Oculus Downgrader — Linux (bash) port

A from-scratch **bash** reimplementation of [ComputerElite's Oculus
Downgrader](https://github.com/ComputerElite/Oculus-downgrader) for Linux.

It downloads specific (older) versions of Oculus / Meta **Quest**, **Go**,
**GearVR** and **Rift** apps straight from Meta's CDN and, for Quest-family
headsets, installs them onto a connected device over **ADB**.

The original is a Windows C# app. Its Quest sideloading path ports cleanly to
Linux; its Rift *install/launch* path does not (it copies files into
`C:\…\Oculus\Software` and launches a Windows `.exe`). So here:

| Feature | Quest / Go / GearVR | Rift (PC) |
|---|---|---|
| Search | ✅ | ✅ |
| List versions | ✅ | ✅ |
| Download | ✅ APK + OBBs | ✅ manifest + segments → game files |
| Install | ✅ via `adb` | ⚠️ Windows-only runtime — files only |

## Requirements

- `bash` 4+, `curl`, `jq` (required)
- `adb` — to install onto a Quest
- `aapt` — recommended, for clean upgrades + OBB placement (reads the APK's package id)
- `python3` + `unzip` — required for **Rift** downloads (fast in-process assembly,
  decompression and SHA-256 verification)

Debian/Ubuntu: `sudo apt install curl jq adb aapt qpdf unzip`
Arch: `sudo pacman -S curl jq android-tools qpdf unzip` (aapt via AUR)

## Logging in

You need to authenticate as **yourself** (you can only download apps you own).
Two ways, same as the original:

### 1. Browser login (recommended)

```bash
./oculus-downgrader.sh login
```

This opens Meta's login page in your browser (`xdg-open`). Log in and approve;
the page then tries to redirect to a `oculus://…?token=…&blob=…` URL that the
browser can't open. Grab that URL and paste it back:

- **Easiest:** open DevTools (F12) → **Network** tab *before* approving, find the
  `approve` request, and copy the `uri` from its JSON response; **or**
- copy whatever `oculus://…` URL your browser shows in its error/prompt.

The tool decrypts the blob and upgrades it to a full user token automatically
(the original did this with an embedded Chromium; here you do the one copy/paste
step manually since there's no headless browser dependency).

### 2. Paste a token manually

If you already have a token (starts with `FRL` or `OC`), grab it via
<https://computerelite.github.io/tools/Oculus/ObtainTokenNew.html> and run:

```bash
./oculus-downgrader.sh token          # prompts, or:
./oculus-downgrader.sh token FRL...
```

> The token is stored in plaintext at `~/.config/oculus-downgrader/config.json`
> (mode `600`).

## Usage

```bash
./oculus-downgrader.sh                 # interactive menu

./oculus-downgrader.sh headset Quest   # Quest, Quest3, Quest3S, QuestPro, Rift, GearVR, Go
./oculus-downgrader.sh login           # log in via the browser
./oculus-downgrader.sh token           # or paste a token manually
./oculus-downgrader.sh search "beat saber"
./oculus-downgrader.sh versions 2448060205267927
./oculus-downgrader.sh download --appid 2448060205267927 --versionid 36522858274028017
./oculus-downgrader.sh install  --appid 2448060205267927 --versionid 36522858274028017
./oculus-downgrader.sh list
```

`download` also accepts `--versioncode <n>` or `--versionstring <s>` instead of
`--versionid`, and `--dest <dir>` to choose the output directory.

## How it works

- **Search / versions** come from the [OculusDB](https://oculusdb.rui2015.me)
  REST API, falling back to Meta's GraphQL endpoint.
- Before downloading, the app's **release channel** is selected via a GraphQL
  mutation so the CDN entitlement check passes (needs your user token).
- **Quest**: the APK is pulled from `securecdn.oculus.com/binaries/download`;
  OBBs are discovered via OculusDB / GraphQL and downloaded alongside.
- **Rift**: the version manifest is fetched, its file **segments** are
  downloaded in parallel (deduplicated by SHA-256), zlib-decompressed and
  concatenated back into the original files.

### Reliability (Rift)

Large Rift games are ~2 GB across thousands of segments, so the odd segment can
fail or arrive truncated. The download is built to survive that:

- Segment downloads use **HTTP/1.1** (Oculus's CDN resets HTTP/2 streams on
  large objects) and verify the full `Content-Length` arrived, retrying on
  truncation. If a stream keeps getting reset mid-transfer, it falls back to a
  **chunked Range download** (1 MiB pieces) to recover the segment.
- Assembly + verification runs in a **single Python process** (no thousands of
  per-file/per-segment subprocess spawns), so it's fast even for 2000+ files.
- Every reconstructed file is checked against the **SHA-256 in the manifest**.
- A clean download converges in two passes (identify what's missing → fetch →
  assemble + verify). Any file that still fails triggers a **repair** that
  re-fetches only that file's segments.
- Downloads are **resumable**: already-verified files and already-fetched
  segments are skipped, so re-running the same command continues where it left
  off. If it still can't finish, progress is kept and it tells you to re-run.
- The download manifest is stored **outside** the game folder, so games that
  ship their own `manifest.json` (e.g. Echo VR) can't clobber it.
- If a segment genuinely can't be fetched (Oculus's CDN advertises the size but
  refuses to serve part of the data — some old versions are partially
  unavailable on their servers), the tool **stops with a clear report** of how
  many files completed and which ones couldn't, instead of looping forever. The
  files that did download are kept.

## Paths

- Config: `${XDG_CONFIG_HOME:-~/.config}/oculus-downgrader/config.json`
- Downloads: `${XDG_DATA_HOME:-~/.local/share}/oculus-downgrader/apps/<appId>/<binaryId>/`

## Notes / limitations

- Token encryption from the original (AES + password) is replaced by a
  `chmod 600` plaintext store — simpler and honest about what it is.
- Browser login **is** ported (`login`), but without the embedded Chromium the
  original used to auto-capture the redirect — you do one copy/paste of the
  `oculus://` URL instead.
- QuestPatcher modding is not integrated; patch the downloaded APK separately
  if you want mods.
