#! /usr/bin/env bash

# This program is free software: you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation, either version 2 of
# the License, or (at your option) any later version. You should
# have received a copy of the GNU General Public License along with
# this program. If not, see https://www.gnu.org/licenses/gpl.html
#
# curl -SsfL https://github.com/hackerschoice/bincrypter/releases/latest/download/bincrypter -o bincrypter
# chmod +x bincrypter
# ./bincrypter -h
#
#
# https://github.com/hackerschoice/bincrypter

[ -t 2 ] && {
CDR="\033[0;31m" # red
CDG="\033[0;32m" # green
CDY="\033[0;33m" # yellow
CDM="\033[0;35m" # magenta
CM="\033[1;35m" # magenta
CDC="\033[0;36m" # cyan
CN="\033[0m"     # none
CF="\033[2m"     # faint
}

# %%BEGIN_BC_ALL%%
_bc_usage() {
    local bc="${0##*/}"
    echo -en >&2 "\
${CM}Encrypt or obfuscate a binary or script.${CDM}

${CDG}Usage:${CN}
${CDC}${bc} ${CDY}[-hql] [file] [password]${CN}
   -h   This help
   -q   Quiet mode (no output)
   -l   Lock binary to this system & UID and fail if copied.
        On failure, do not execute the encrypted binary. Instead:
        1. exit with 0 if BC_LOCK is not set. [default]
        2. exit with BC_LOCK if set to a numerical value.
        3. Execute BC_LOCK. (can be a base64 encoded strings).

${CDG}Environment variables (optional):${CN}
${CDY}PASSWORD=${CN}     Password to encrypt/decrypt.
${CDY}BC_PASSWORD=${CN}  Password to encrypt/decrypt (exported to callee).
${CDY}BC_PADDING=n${CN}  Add 0..n% of random data to the binary [default: 25].
${CDY}BC_QUIET=${CN}     See -q
${CDY}BC_LOCK=${CN}      See -l

${CDG}Examples:${CN}
Obfuscate myfile.sh:
  ${CDC}${bc} ${CDY}myfile.sh${CN}

Obfuscate /usr/bin/id (via pipe):
  ${CDC}cat ${CDY}/usr/bin/id${CN} | ${CDC}${bc}${CN} >${CDY}id.enc${CN}

Obfuscate & Lock to system. Execute 'id; uname -a' if copied (2 variants):
  1. ${CDY}BC_LOCK='id; uname -a' ${CDC}${bc} ${CDY}myfile.sh${CN}
  2. ${CDY}BC_LOCK='aWQ7IHVuYW1lIC1hCg==' ${CDC}${bc} ${CDY}myfile.sh${CN}

Encrypt myfile.sh with password 'mysecret':
  ${CDC}${bc} ${CDY}myfile.sh ${CDY}mysecret${CN}

Encrypt by passing the password as environment variable:
  ${CDY}PASSWORD=mysecret ${CDC}${bc} ${CDY}myfile.sh${CN}
"
    exit 0
} # EO _bc_usage

_bc_dogetopt() {
    [ -t 0 ] && [ $# -eq 0 ] && _bc_usage
    while getopts "hql" opt; do
        case $opt in
            h) _bc_usage ;;
            q) _OPT_BC_QUIET=1 ;;
            l) _OPT_BC_LOCK=0 ;;
            *) ;;
        esac
    done
    shift $((OPTIND - 1))
}

# %%BEGIN_BC_FUNC%%
_bincrypter() {
    local str ifn fn s c DATA P _P S HOOK _PASSWORD
    local USE_PERL=1
    local _BC_QUIET
    local _BC_LOCK

    # vampiredaddy wants this to work if dd + tr are not available:
    if [ -n "$USE_PERL" ]; then
        _bc_xdd() { [ -z "$DEBUG" ] && LANG=C perl -e 'read(STDIN,$_, '"$1"'); print;'; }
        _bc_xtr() { LANG=C perl -pe 's/['"${1}${2}"']//g;'; }
        _bc_xprintf() { LANG=C perl -e "print(\"$1\")"; }
    else
        _bc_xdd() { [ -z "$DEBUG" ] && dd bs="$1" count=1 2>/dev/null;}
        _bc_xtr() { tr -d"${1:+c}" "${2}";}
        _bc_xprintf() { printf "$@"; }
    fi

    _BC_QUIET="${BC_QUIET:-$_OPT_BC_QUIET}"
    _BC_LOCK="${BC_LOCK:-$_OPT_BC_LOCK}"

    _bc_err() {
        echo -e >&2 "${CDR}ERROR${CN}: $*"
        # Be opportunistic: Try to obfuscate but if that fails then just copy data
        # without obfuscation (cat).
        # Consider a system where there is no 'openssl' or 'perl' but the install
        # pipeline looks like this:
        # curl -fL https://foo.com/script | bincrypter -l >script
        # => We rather have a non-obfuscated binary than NONE.
        [ "$fn" = "-" ] && {
            cat    # Pass through
            return 0 # Make pipe succeed
        }
        return 255
    }
    # Obfuscate a string with non-printable characters at random intervals.
    # Input must not contain \ (or sh gets confused)
    _bc_ob64() {
        local i
        local h="$1"
        local str
        local x
        local s

        # Always start with non-printable character
        s=0
        while [ ${#h} -gt 0 ]; do
            i=$((1 + RANDOM % 4))
            str+=${h:0:$s}
            [ ${#x} -le $i ] && x=$(_bc_xdd 128 </dev/urandom | _bc_xtr '' '[:print:]\0\n\t')
            str+=${x:0:$i}
            x=${x:$i}
            h=${h:$s}
            s=$((1 + RANDOM % 3))
        done
        echo "$str"
    }

    # Obfuscate a string with `#\b`
    _bc_obbell() {
        local h="$1"
        local str
        local x
        local s

        [ -n "$DEBUG" ] && { echo "$h"; return; }
        while [ ${#h} -gt 0 ]; do
            s=$((1 + RANDOM % 4))
            str+=${h:0:$s}
            if [ $((RANDOM % 2)) -eq 0 ]; then
                str+='`! :&&'$'\b''#`' #backspace
                # Android's fake-bourne shell has problems with this line:
                # str+='`#'$'\b''`' #backspace
            else
                str+='`:||'$'\a''`' #alert/bell
            fi
            h=${h:$s}
        done
        echo "$str"
    }

    # Sets _P
    # Return 0 to continue. Otherwise caller should return.
    # May exit if bin is executed on another host (BC_LOCK).
    # This function is baked into the decrypter-hook
    _bcl_gen_p() {
        local _k
        local str
        # Binary is LOCKED to this host. Check if this is the same host to allow execution.
        [ -z "$BC_BCL_TEST_FAIL" ] && _k="$(_bcl_get)" && _P="$(echo "$1" | openssl enc -d -aes-256-cbc -md sha256 -nosalt -k "$_k" -a -A 2>/dev/null)"
        # [ -n "$DEBUG" ] && echo >&2 "_k=$_k _P=$_P"
        [ -n "$_P" ] && return 0
        [ -n "$fn" ] && {
            # sourced
            unset BCL BCV _P P S fn
            unset -f _bcl_get _bcl_verify _bcl_verify_dec
            return 255
        }
        # base64 to string
        BCL="$(echo "$BCL" | openssl base64 -d -A 2>/dev/null)"
        # Check if BCL is a number and exit with that number.
        [ "$BCL" -eq "$BCL" ] 2>/dev/null && exit "$BCL"
        # 2nd decode (optional)
        str="$(echo "$BCL" | openssl base64 -d -A 2>/dev/null)"
        BCL="${str:-$BCL}"
        exec /bin/sh -c "$BCL"
        exit 255 # FATAL
    }
    # Hack to stop VSCODE from marking _bcl_gen_p as unreached:
    :||_bcl_gen_p ""

    _bcl_gen() {
        local _k
        local p
        # P:=Encrypt(P) using _bcl_get as key
        _k="$(_bcl_get)"
        # [ -n "$DEBUG" ] && echo >&2 "_k=$_k P=$P"
        [ -z "$_k" ] && { echo -e >&2 "${CDR}ERROR${CN}: BC_LOCK not supported on this system"; return 255; }
        p="$(echo "$P" | openssl enc -aes-256-cbc -md sha256 -nosalt -k "${_k}" -a -A 2>/dev/null)"
        [ -z "$p" ] && { echo -e >&2 "${CDR}ERROR${CN}: Failed to generate BC_LOCK password"; return 255; }
        P="$p"
        str+="$(declare -f _bcl_verify_dec)"$'\n'
        str+="_bcl_verify() { _bcl_verify_dec \"\$@\"; }"$'\n'
        str+="$(declare -f _bcl_get)"$'\n'
        str+="$(declare -f _bcl_gen_p)"$'\n'
        str+="BCL='$(openssl base64 -A <<<"${_BC_LOCK}")'"$'\n'
        # Add test value
        str+="BCV='$(echo TEST-VALUE-VERIFY | openssl enc -aes-256-cbc -md sha256 -nosalt -k "B-${_k}" -a -A 2>/dev/null)'"$'\n'
    }
    # Test a key candidate and on success output the candidate to STDOUT.
    _bcl_verify_dec() {
        [ "TEST-VALUE-VERIFY" != "$(echo "$BCV" | openssl enc -d -aes-256-cbc -md sha256 -nosalt -k "B-${1}-${UID}" -a -A 2>/dev/null)" ] && return 255
        echo "$1-${UID}"
    }
    # Encrypt & Decrypt BCV for testing.
    _bcl_verify() {
        [ -z "$1" ] && return 255
        # [ "TEST-VALUE-VERIFY" != "$(echo "$BCV" | openssl enc -d -aes-256-cbc -md sha256 -nosalt -k "${1}" -a -A 2>/dev/null)" ] && return 255
        echo "$1-${UID}"
    }
    :||_bcl_verify

    # Generate a LOCK key and output it to STDOUT (if valid).
    # This script uses the above bcl_verify but the decoder uses its own
    # bcl_verify as a trampoline to call bcl_verify_dec.
    # FIXME: Consider cases where machine-id changes. Fallback to dmidecode and others....
    _bcl_get() {
        [ -z "$UID" ] && UID="$(id -u 2>/dev/null)"
        [ -f "/etc/machine-id" ] && _bcl_verify "$(cat "/etc/machine-id" 2>/dev/null)" && return
        command -v dmidecode >/dev/null && _bcl_verify "$(dmidecode -t 1 2>/dev/null | LANG=C perl -ne '/UUID/ && print && exit')" && return
        _bcl_verify "$({ ip l sh dev "$(LANG=C ip route show match 1.1.1.1 | perl -ne 's/.*dev ([^ ]*) .*/\1/ && print && exit')" | LANG=C perl -ne 'print if /ether / && s/.*ether ([^ ]*).*/\1/';} 2>/dev/null)" && return
        _bcl_verify "$({ blkid -o export | LANG=C perl -ne '/^UUID/ && s/[^[:alnum:]]//g && print && exit';} 2>/dev/null)" && return
        _bcl_verify "$({ fdisk -l | LANG=C perl -ne '/identifier/i && s/[^[:alnum:]]//g && print && exit';} 2>/dev/null)" && return
    }

    fn="-"
    [ "$#" -gt 0 ] && fn="$1" # $1 might be '-'
    [ "$fn" != "-" ] && [ ! -f "$fn" ] && { _bc_err "File not found: $fn"; return; }
    [ "$fn" != "-" ] && [ ! -r "$fn" ] && { _bc_err "File not readable: $fn"; return; }

    [ -n "$BC_BCL_TEST_FAIL_COMMAND" ] && { _bc_err "$BC_BCL_TEST_FAIL_COMMAND is required (fn=$fn)"; return; }
    command -v openssl >/dev/null || { _bc_err "openssl is required"; return; }
    command -v perl >/dev/null || { _bc_err "perl is required"; return; }
    command -v gzip >/dev/null || { _bc_err "gzip is required"; return; }
    [ ! -c "/dev/urandom" ] && { _bc_err "/dev/urandom is required"; return; }

    # Auto-generate password if not provided
    _PASSWORD="${2:-${PASSWORD:-$BC_PASSWORD}}"

    [ -n "$_BC_LOCK" ] && [ -n "$_PASSWORD" ] && { echo -e >&2 "${CDR}WARN${CN}: ${CDY}PASSWORD${CN} is ignored when using ${CDY}BC_LOCK${CN}."; unset _PASSWORD; }
    [ -z "$_PASSWORD" ] && P="$(DEBUG='' _bc_xdd 32 </dev/urandom | openssl base64 -A | _bc_xtr '^' '[:alnum:]' | DEBUG='' _bc_xdd 16)"
    _P="${_PASSWORD:-$P}"
    [ -z "$_P" ] && { _bc_err "No ${CDC}PASSWORD=<password>${CN} provided and failed to generate one."; return; }
    unset _PASSWORD
    # [ -n "$DEBUG" ] && echo >&2 "generated P=${P}"

    # Auto-generate SALT
    S="$(DEBUG='' _bc_xdd 32 </dev/urandom | openssl base64 -A | _bc_xtr '^' '[:alnum:]' | DEBUG='' _bc_xdd 16)"

    # base64 encoded decrypter
    HOOK='Zm9yIHggaW4gb3BlbnNzbCBwZXJsIGd1bnppcDsgZG8KICAgIGNvbW1hbmQgLXYgIiR4IiA+L2Rldi9udWxsIHx8IHsgZWNobyA+JjIgIkVSUk9SOiBDb21tYW5kIG5vdCBmb3VuZDogJHgiOyByZXR1cm4gMjU1OyB9CmRvbmUKdW5zZXQgZm4gX2VycgppZiBbIC1uICIkWlNIX1ZFUlNJT04iIF07IHRoZW4KICAgIFsgIiRaU0hfRVZBTF9DT05URVhUIiAhPSAiJHtaU0hfRVZBTF9DT05URVhUJSI6ZmlsZToiKn0iIF0gJiYgZm49IiQwIgplbGlmIFsgLW4gIiRCQVNIX1ZFUlNJT04iIF07IHRoZW4KICAgIChyZXR1cm4gMCAyPi9kZXYvbnVsbCkgJiYgZm49IiR7QkFTSF9TT1VSQ0VbMF19IgpmaQpmbj0iJHtCQ19GTjotJGZufSIKWFM9IiR7QkFTSF9FWEVDVVRJT05fU1RSSU5HOi0kWlNIX0VYRUNVVElPTl9TVFJJTkd9IgpbIC16ICIkWFMiIF0gJiYgdW5zZXQgWFMKWyAteiAiJGZuIiBdICYmIFsgLXogIiRYUyIgXSAmJiBbICEgLWYgIiQwIiBdICYmIHsKICAgIGVjaG8gPiYyICdFUlJPUjogU2hlbGwgbm90IHN1cHBvcnRlZC4gVHJ5ICJCQ19GTj1GaWxlTmFtZSBzb3VyY2UgRmlsZU5hbWUiJwogICAgX2Vycj0xCn0KX2JjX2RlYygpIHsKICAgIF9QPSIke1BBU1NXT1JEOi0kQkNfUEFTU1dPUkR9IgogICAgdW5zZXQgXyBQQVNTV09SRCAKICAgIGlmIFsgLW4gIiRQIiBdOyB0aGVuCiAgICAgICAgaWYgWyAtbiAiJEJDViIgXSAmJiBbIC1uICIkQkNMIiBdOyB0aGVuCiAgICAgICAgICAgIF9iY2xfZ2VuX3AgIiRQIiB8fCByZXR1cm4KICAgICAgICBlbHNlCiAgICAgICAgICAgIF9QPSIkKGVjaG8gIiRQInxvcGVuc3NsIGJhc2U2NCAtQSAtZCkiCiAgICAgICAgZmkKICAgIGVsc2UKICAgICAgICBbIC16ICIkX1AiIF0gJiYgewogICAgICAgICAgICBlY2hvID4mMiAtbiAiRW50ZXIgcGFzc3dvcmQ6ICIKICAgICAgICAgICAgcmVhZCAtciBfUAogICAgICAgIH0KICAgIGZpCiAgICBbIC1uICIkQyIgXSAmJiB7CiAgICAgICAgbG9jYWwgc3RyCiAgICAgICAgc3RyPSIkKGVjaG8gIiRDIiB8IG9wZW5zc2wgZW5jIC1kIC1hZXMtMjU2LWNiYyAtbWQgc2hhMjU2IC1ub3NhbHQgLWsgIkMtJHtTfS0ke19QfSIgLWEgLUEgMj4vZGV2L251bGwpIgogICAgICAgIHVuc2V0IEMKICAgICAgICBbIC16ICIkc3RyIiBdICYmIHsKICAgICAgICAgICAgWyAtbiAiJEJDTCIgXSAmJiBlY2hvID4mMiAiRVJST1I6IERlY3J5cHRpb24gZmFpbGVkLiIKICAgICAgICAgICAgcmV0dXJuIDI1NQogICAgICAgIH0KICAgICAgICBldmFsICIkc3RyIgogICAgICAgIHVuc2V0IHN0cgogICAgfQogICAgWyAtbiAiJFhTIiBdICYmIHsKICAgICAgICBleGVjIGJhc2ggLWMgIiQocHJpbnRmICVzICIkWFMiIHxMQU5HPUMgcGVybCAtZSAnPD47PD47cmVhZChTVERJTiwkXywxKTt3aGlsZSg8Pil7cy9CMy9cbi9nO3MvQjEvXHgwMC9nO3MvQjIvQi9nO3ByaW50fSd8b3BlbnNzbCBlbmMgLWQgLWFlcy0yNTYtY2JjIC1tZCBzaGEyNTYgLW5vc2FsdCAtayAiJHtTfS0ke19QfSIgMj4vZGV2L251bGx8TEFORz1DIHBlcmwgLWUgInJlYWQoU1RESU4sXCRfLCAke1I6LTB9KTtwcmludCg8PikifGd1bnppcCkiCiAgICB9CiAgICBbIC16ICIkZm4iIF0gJiYgWyAtZiAiJDAiIF0gJiYgewogICAgICAgIHpmPSdyZWFkKFNURElOLFwkXywxKTt3aGlsZSg8Pil7cy9CMy9cbi9nO3MvQjEvXFx4MDAvZztzL0IyL0IvZztwcmludH0nCiAgICAgICAgcHJnPSJwZXJsIC1lICc8Pjs8PjskemYnPCckezB9J3xvcGVuc3NsIGVuYyAtZCAtYWVzLTI1Ni1jYmMgLW1kIHNoYTI1NiAtbm9zYWx0IC1rICcke1N9LSR7X1B9JyAyPi9kZXYvbnVsbHxwZXJsIC1lICdyZWFkKFNURElOLFxcXCRfLCAke1I6LTB9KTtwcmludCg8PiknfGd1bnppcCIKICAgICAgICBMQU5HPUMgZXhlYyBwZXJsICctZSReRj0yNTU7Zm9yKDMxOSwyNzksMzg1LDQzMTQsNDM1NCl7KCRmPXN5c2NhbGwkXywkIiwwKT4wJiZsYXN0fTtvcGVuKCRvLCI+Jj0iLiRmKTtvcGVuKCRpLCInIiRwcmciJ3wiKTtwcmludCRvKDwkaT4pO2Nsb3NlKCRpKXx8ZXhpdCgkPy8yNTYpOyRFTlZ7IkxBTkcifT0iJyIkTEFORyInIjtleGVjeyIvcHJvYy8kJC9mZC8kZiJ9IiciJHswOi1weXRob24zfSInIixAQVJHVjtleGl0IDI1NScgLS0gIiRAIgogICAgfQogICAgWyAtZiAiJHtmbn0iIF0gJiYgewogICAgICAgIHVuc2V0IC1mIF9iY2xfZ2V0IF9iY2xfdmVyaWZ5IF9iY2xfdmVyaWZ5X2RlYwogICAgICAgIHVuc2V0IEJDTCBCQ1YgXyBQIF9lcnIKICAgICAgICBldmFsICJ1bnNldCBfUCBTIFIgZm47JChMQU5HPUMgcGVybCAtZSAnPD47PD47cmVhZChTVERJTiwkXywxKTt3aGlsZSg8Pil7cy9CMy9cbi9nO3MvQjEvXHgwMC9nO3MvQjIvQi9nO3ByaW50fSc8IiR7Zm59InxvcGVuc3NsIGVuYyAtZCAtYWVzLTI1Ni1jYmMgLW1kIHNoYTI1NiAtbm9zYWx0IC1rICIke1N9LSR7X1B9IiAyPi9kZXYvbnVsbHxMQU5HPUMgcGVybCAtZSAicmVhZChTVERJTixcJF8sICR7UjotMH0pO3ByaW50KDw+KSJ8Z3VuemlwKSIKICAgICAgICByZXR1cm4KICAgIH0KICAgIFsgLXogIiRmbiIgXSAmJiByZXR1cm4KICAgIGVjaG8gPiYyICJFUlJPUjogRmlsZSBub3QgZm91bmQ6ICRmbiIKICAgIF9lcnI9MQp9ClsgLXogIiRfZXJyIiBdICYmIF9iY19kZWMgIiRAIgp1bnNldCBmbgp1bnNldCAtZiBfYmNfZGVjCmlmIFsgLW4gIiRfZXJyIiBdOyB0aGVuCiAgICB1bnNldCBfZXJyCiAgICBmYWxzZQplbHNlCiAgICB0cnVlCmZpCg=='

    # _P - used with openssl below. AS INSERTED BY USER _or_ GENERATED.
    #  P - Generated. Stored in P=base64($P).
    # [ -n "$DEBUG" ] && echo >&2 "OpenSSL ENC with _P=$_P (P='$P')"
    unset str _C R
    # P:=Encrypted(P) using HOST-ID as encryption-key. Resets $str.
    [ -n "$_BC_LOCK" ] && _bcl_gen
    [ -z "$str" ] && {
        # NOT using BC_LOCK (Fallback)
        str="unset BCV BCL"$'\n'
        # P is not set if provided via ENV or $2
        [ -n "$P" ] && P="$(echo "$P"|openssl base64 -A 2>/dev/null)"
    }

    # Always base64 encode.
    ## Add Password to script ($P might be encrypted if BC_LOCK is set)
    [ -n "$P" ] && {
        # [ -n "$DEBUG" ] && echo >&2 "Store P=${P}"
        str+="P=${P}"$'\n'
        unset P
    }

    ## Add SALT to script
    str+="S='$S'"$'\n'

    # Bash strings are not binary safe. Instead, store the binary as base64 in memory:
    ifn="$fn"
    [ "$fn" = "-" ] && ifn="/dev/stdin"
    DATA="$(gzip <"$ifn" | openssl base64)" || return 255

    ## Add size of random padding to script (up to roughly 25% of the file size)).
    [ "$BC_PADDING" != "0" ] && {
        local sz="${#DATA}"
        [ "$sz" -lt 31337 ] && sz=31337
        R="$(( (RANDOM * 32768 + RANDOM) % ((sz / 100) * ${BC_PADDING:-25})))"
    }
    _C+="R=${R:-0}"$'\n'

    ## Add encrypted configs to script
    [ -n "$_C" ] && {
        [ -n "$DEBUG" ] && echo >&2 "Store C=ENC('${_C}')"
        str+="C=$(echo "$_C" | openssl enc -aes-256-cbc -md sha256 -nosalt -k "C-${S}-${_P}" -a -A 2>/dev/null)"$'\n'
    }

    str+="$(echo "$HOOK"|openssl base64 -A -d)"
    [ -n "$DEBUG" ] && { echo -en >&2 "DEBUG: ===code===\n${CDM}${CF}"; echo >&2 "$str"; echo -en >&2 "${CN}"; }
    ## Encode & obfuscate the HOOK
    HOOK="$(echo "$str" | openssl base64 -A)"
    HOOK="$(_bc_ob64 "$HOOK")"

    [ -z "$_BC_QUIET" ] && [ "$fn" != "-" ] && { 
        s="$(stat -c %s "$fn")"
        [ "$s" -gt 0 ] || { _bc_err "Empty file: $fn"; return; }
    }

    [ "$fn" = "-" ] && fn="/dev/stdout"

    # Create the encrypted binary: /bin/sh + Decrypt-Hook + Encrypted binary
    { 
        # printf '#!/bin/sh\0#'
        # Add some binary data after shebang, including \0 (sh reads past \0 but does not process. \0\n count as new line).
        # dd count="${count:-1}" bs=$((1024 + RANDOM % 1024)) if=/dev/urandom 2>/dev/null| tr -d "[:print:]\n'"
        # echo "" # Newline
        # => Unfortunately some systems link /bin/sh -> bash.
        # 1. Bash checks that the first line is binary free.
        # 2. and no \0 in the first 80 bytes (including the #!/bin/sh)
        echo '#!/bin/sh'
        # Add dummy variable containing garbage (for obfuscation) (2nd line)
        echo -n "_='" 
        _bc_xdd 66 </dev/urandom | _bc_xtr '' "[:print:]\0\n'"
        # \0\0 confuses some shells.
        _bc_xdd "$((1024 + RANDOM % 4096))" </dev/urandom| _bc_xtr '' "[:print:]\0{2,}\n'"
        # _bc_xprintf "' \x00" # WORKS ON BASH ONLY
        _bc_xprintf "';" # works on BASH + ZSH
        # far far far after garbage
        ## Add my hook to decrypt/execute binary
        # echo "eval \"\$(echo $HOOK|strings -n1|openssl base64 -d)\""
        echo "$(_bc_obbell 'eval "')\$$(_bc_obbell '(echo ')$HOOK|LANG=C $(_bc_obbell "perl -pe \"s/[^[:print:]]//g\"")$(_bc_obbell "|openssl base64 -A -d)")\""
        # Add the encrypted binary (from memory)
        # ( DEBUG='' _bc_xdd "${R:-0}" </dev/urandom; openssl base64 -d<<<"$DATA") |openssl enc -aes-256-cbc -md sha256 -nosalt -k "${S}-${_P}" 2>/dev/null | LANG=C perl -pe 's/B/B2/g; s/\x00/B1/g'
 
        # To support 'BC_FN=h.sh eval "$(<h.sh)"' we need to have all binary data in one single
        # line and pre-fixed with '#' to prevent execution.
        echo -n '#'
        ( DEBUG='' _bc_xdd "${R:-0}" </dev/urandom; openssl base64 -d<<<"$DATA") |openssl enc -aes-256-cbc -md sha256 -nosalt -k "${S}-${_P}" 2>/dev/null | LANG=C perl -pe 's/B/B2/g; s/\x00/B1/g; s/\n/B3/g'
    } > "$fn"

    [ -n "$s" ] && {
        c="$(stat -c %s "$fn" 2>/dev/null)"
        [ -n "$c" ] && echo -e >&2 "${CDY}Compressed:${CN} ${CDM}$s ${CF}-->${CN}${CDM} $c ${CN}[${CDG}$((c * 100 / s))%${CN}]"
    }
    # [ -z "$_BC_QUIET" ] && [ -n "$_BC_LOCK" ] && echo -e >&2 "${CDY}PASSWORD=${CF}${_P}${CN}"
    unset -f _bc_usage _bcl_get _bcl_verify _bcl_verify_dec _bc_err _bc_ob64 _bc_obbell _bc_xdd _bc_xtr _bc_xprintf
    [ -z "$_BC_QUIET" ] && echo -e >&2 "${CDG}Done${CN}"
    return 0
}
# %%END_BC_FUNC%%

# Check if sourced or executed
[ -n "$ZSH_VERSION" ] && [ "$ZSH_EVAL_CONTEXT" != "${ZSH_EVAL_CONTEXT%":file:"*}" ] && _sourced=1
(return 0 2>/dev/null) && _sourced=1
[ -z "$_sourced" ] && {
    # Execute if not sourced:
    _bc_dogetopt "$@"
    _bincrypter "$@"
    exit
}

### HERE: sourced
bincrypter() {
    _bc_dogetopt "$@"
    _bincrypter "$@"
}
unset _sourced
