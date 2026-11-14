# opencode-termux

[![build-deb-source](https://github.com/jcz2020/opencode-termux/actions/workflows/build-deb-source.yml/badge.svg)](https://github.com/jcz2020/opencode-termux/actions/workflows/build-deb-source.yml)
[![release](https://img.shields.io/github/v/release/jcz2020/opencode-termux)](https://github.com/jcz2020/opencode-termux/releases)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**opencode that actually works on Termux / Android.**

[中文](README.md) · [Build it yourself](docs/BUILD.md) · [How it works & dev notes](docs/spike-android-bun.md)

---

## Why this exists

The official opencode Linux build is a glibc binary and won't run on Termux (bionic)
as-is. Community Termux packages do run, but on **Android 11 and newer** (tested here
up to Android 16 / API 36) the TUI dies immediately:

```
Error: Pointer exceeds safe integer range
```

bionic tags heap pointers in the top byte (`malloc` returns `0xb4000077f0c1b6f0`).
Bun's FFI passes that pointer to libopentui as a JS number, which exceeds `2^53`
and throws. **This is a runtime problem, not a compilation problem** — 2.1.4 and
2.2.5 crash identically.

This project fixes it, and **depends on no third-party Termux packaging**:

| Component | Where it comes from |
|---|---|
| `opencode` itself | built from upstream source with the official Android Bun |
| `libopentui.so` (TUI rendering) | compiled by us — Zig + NDK, for bionic |
| `librust_pty.so` (command execution / terminal panel) | compiled by us — Rust + NDK, for bionic |
| `libnoheap.so` (disable heap tagging) | 6 KB of C in this repo |

The standalone runtime bundle additionally ships `git` 2.56.1 (with HTTPS helper),
`ripgrep` 15.2.0, `gh` 2.104.0, `fd` 10.5.2, `jq` 1.8.2, `busybox` 1.38.0
and their shared-library dependencies for Android apps to execute from
`nativeLibraryDir`; the deb does not duplicate these tools.

---

## Install

### Requirements

- Android 11 or newer (older may work, untested; verified on Android 16)
- Ready for Android 15/16 **16 KB page** devices: every ELF `PT_LOAD` is 16 KB aligned
- [Termux](https://termux.dev) (F-Droid or GitHub build)
- **aarch64** (most modern phones; only aarch64 packages are published)

### One-liner Installation & Upgrade (Recommended)

Automatic mirror acceleration for mainland China networks with seamless failover and SHA-256 verification:

```sh
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/jcz2020/opencode-termux/main/scripts/install-termux.sh | bash
```

> **Direct / International connections**:
> ```sh
> curl -fsSL https://raw.githubusercontent.com/jcz2020/opencode-termux/main/scripts/install-termux.sh | bash
> ```

The installer detects your network environment, picks the fastest available candidate, and verifies the package hash. Re-running it acts as an in-place upgrade tool.

### Upgrading OpenCode

After installation, the standard update command is intercepted and securely upgraded to our latest Termux package:

```sh
opencode update            # check and upgrade to the latest compatible release
opencode update --check    # check for available updates without installing
```

### Manual Installation

To download the `.deb` package manually:

```sh
# Current latest: v2.3.0+termux5
pkg install -y curl jq
id=$(curl -sS "https://api.github.com/repos/jcz2020/opencode-termux/releases/tags/v2.3.0+termux5" \
     | jq -r '.assets[] | select(.name|endswith(".deb")) | .id')
curl -sSL -C - -H 'Accept: application/octet-stream' -o opencode.deb \
  "https://api.github.com/repos/jcz2020/opencode-termux/releases/assets/$id"
dpkg -i opencode.deb
```

### Verify

```sh
opencode --version      # → opencode v2.3.0
oc                      # shortcut for opencode
```

`opencode` drops you straight into the TUI. **If the TUI opens but crashes as soon
as you send a message**, that's not a broken install — the free-tier quota ran out
(you'll see `You've used today's free messages`). Switch models with `/models` or
connect your own key with `/connect`.

---

## Usage (TUI & Web UI Dual Modes)

This distribution not only supports the terminal TUI, but also **inlines the complete official Web UI assets into the binary**, allowing graphical browser access on your phone, tablet, or desktop!

### 1. Terminal Mode (TUI)
```sh
opencode
```
Launches the full interactive terminal TUI with syntax highlighting and diff views.

### 2. Browser GUI Mode (Web UI)
Typing and reviewing code on a small touch screen in terminal can be cumbersome. Run the embedded web server to access the modern web interface from your phone's browser (Chrome, Kiwi, Firefox) or any device on your local network:

```sh
# Local access only (phone browser)
opencode serve

# LAN access (accessible from tablets or laptops on the same Wi-Fi)
opencode serve --hostname 0.0.0.0 --port 4096
```

The terminal will print the access URL (e.g. `http://127.0.0.1:4096`). Open it in your browser to enjoy:
- 🌟 **Full Offline Inlining**: All frontend assets are bundled with the binary, completely independent of external CDNs;
- 📱 **Multi-Project & Tab Switching**: File tree browsing, Markdown rendering, and visual Git diff reviews;
- 🔒 **Built-in Authentication**: Protected by server password (`OPENCODE_SERVER_PASSWORD`) or one-time pairing codes.

> 💡 **Tip**: If you prefer a native Android experience (one-tap launch, background foreground service, full edge-to-edge gestures) without touching the command line, check out our standalone companion app [OpenCode for Android](https://github.com/jcz2020/opencode-app).

---

## FAQ

**Q: `opencode: command not found` after installing?**
A: run `hash -r`, and make sure `$PREFIX/bin` is on `PATH`.

**Q: The TUI crashes with `Pointer exceeds safe integer range`?**
A: the shim isn't loaded. Check `dpkg -S $PREFIX/lib/opencode/libnoheap.so` — it
should print a path. If not, reinstall the package.

**Q: The TUI crashes with `Missing OpenTUI asset ...`?**
A: mismatched package version — `libopentui.so` and the JS-side `@opentui/*`
must be the same version. Reinstall the latest release.

**Q: `You've used today's free messages`?**
A: the free model quota for the day is used up. Not a bug.

**Q: What is `oc`?**
A: a shortcut for `opencode`. The package doesn't ship it — if you installed via the
old `install-opencode.sh` you already have it; otherwise
`ln -s $PREFIX/bin/opencode $PREFIX/bin/oc`.

**Q: Can I upgrade?**
A: yes. The package name stays `opencode` and the version is
`<upstream version>+termux<N>`, so `dpkg -i` of a newer package is an upgrade —
no conflicts, and `apt` won't revert it.

**Q: Does it conflict with Hope2333's `opencode-termux` package?**
A: same package name — pick one. `dpkg -r opencode` before installing this.

**Q: x86_64 / 32-bit support?**
A: not yet, aarch64 only.

**Q: Can I build it myself?**
A: yes — see [docs/BUILD.md](docs/BUILD.md).

---

## Two packaging lines

| Line | Release tag | Package version | Depends on | Size |
|---|---|---|---|---|
| **Source build (primary)** | `v<ver>+termux<N>` | `<ver>+termux<N>` | official Android Bun + NDK + Zig + Rust | 68 MB |
| Mirror repack (fallback) | `v<ver>+mirror<N>` | `<ver>+mirror<N>` | third-party Termux packaging | 82 MB |

The primary line is built from source: apart from opencode's own source, **no
third-party packaging output is involved**. `watch-upstream` checks the upstream
release every 6 hours and publishes a new build automatically.

---

## What gets installed

The source build installs into `$PREFIX`:

| Path | Role |
|---|---|
| `bin/opencode` | wrapper: sets the runtime environment, then execs the real binary |
| `bin/opencode.real` | the actual opencode binary (~200 MiB) |
| `bin/opencode-pty` | the 2.3.0 persistent PTY daemon (static binary) |
| `lib/opencode/libnoheap.so` | disables bionic heap tagging (the key fix) |
| `lib/opencode/libopentui.so` | our bionic build of the TUI native library |
| `lib/opencode/librust_pty.so` | our bionic build of the PTY library |
| `lib/opencode/opentui.h` | native header, for plugins that write their own FFI |

The wrapper does:

```sh
LD_PRELOAD=.../libnoheap.so          # disable heap tagging
OPENTUI_NATIVE_LIB=.../libopentui.so  # tell opentui where its native lib is
BUN_PTY_LIB=.../librust_pty.so        # tell bun-pty where its lib is
OPENCODE_PTY_BIN=.../bin/opencode-pty # 2.3.0 persistent PTY daemon
OPENCODE_PTY_SOCKET_DIR=.../tmp/opty  # Android /tmp is not writable
```

---

## Lessons learned

Full list in [docs/LESSONS.md](docs/LESSONS.md). The one worth remembering:

> **"The step succeeded" is not the same as "the right thing happened".**
> Several bugs in this project were green CI + passing tests + nothing actually
> done: a smoke test that only checked rendering and missed "crashes as soon as
> you use it"; a `$GITHUB_OUTPUT` that never got written so the dispatch was
> silently skipped while the step still reported success.
> Hence: the smoke test now **sends a real prompt**, the checks **statically
> compare FFI symbols**, and every change runs **the e2e script**
> (6 interaction scenarios + 2 on-disk checks).

---

## Background: why the official package can't be reused

npm only carries opencode up to the **v1 family** (`opencode-linux-arm64` tops out
at 1.19.5); there is **no published v2 aarch64 binary**, so v2 must be compiled from
source. Doing that requires two hard pieces:

1. **A Bun that runs on bionic** — historically you had to cross-compile Bun
   yourself. That's no longer necessary: upstream ships
   `bun-linux-aarch64-android` (1.4.4), which is what this project uses.
2. **A bionic `libopentui.so`** (a Zig library, needing cross-compilation plus
   libc++ ABI handling) — this project solved it.

So "building our own Android Bun" turned out to be **unnecessary**; the two native
libraries are the real work.

---

## Credits / references

**We don't patch opencode itself — we make it able to run on bionic.**
These projects are what makes this possible:

- **[anomalyco/opencode](https://github.com/anomalyco/opencode)** — opencode itself
  (MIT); we compile its source. [opencode.ai](https://opencode.ai)
- **[oven-sh/bun](https://github.com/oven-sh/bun)** — ships the official
  `bun-linux-aarch64-android` build that we use to compile opencode (MIT).
- **[anomalyco/opentui](https://github.com/anomalyco/opentui)** — the TUI native
  library; we cross-compile it for bionic (MIT).
- **[sursaone/bun-pty](https://github.com/sursaone/bun-pty)** — the PTY library;
  we cross-compile it for bionic (MIT).
- **[Android bionic](https://android.googlesource.com/platform/bionic/)** — the
  behaviour of `mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, M_HEAP_TAGGING_LEVEL_NONE)`
  comes from bionic's `<malloc.h>`; the whole fix is "read it, flip one process-wide switch".
- **[Termux](https://termux.dev)** — the `dpkg`/`apt` packaging path, the umask-077
  pitfall, and the tmux-based smoke-testing technique.
- **[Hope2333/opencode-termux](https://github.com/Hope2333/opencode-termux)** —
  we originally learned the package layout and the "what you must not do" boundaries
  from its implementation, and its `libopencode-crhandler.so` (SIGSYS→ENOSYS)
  inspired ours. **The primary line here does not depend on its artifacts.**

This repository ships **no upstream binaries** (`cache/` and `dist/` are
gitignored); they are fetched and sha256-verified at build time.

---

## License

This project's own code (`src/`, `scripts/`, `spike/`, `Makefile`) is MIT — see
[LICENSE](LICENSE). The opencode binary inside the package remains upstream's
(MIT); see [NOTICE](NOTICE).
