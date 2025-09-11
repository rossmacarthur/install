#!/bin/bash

set -eu -o pipefail

# This is just a little script that can be downloaded from the internet to
# install a Rust crate from a GitHub release. It determines the latest release,
# the current platform (without the need for `rustc`), and installs the
# extracted binary to the specified location.

usage() {
    cat 1>&2 <<EOF
Install a binary release of a Rust crate hosted on GitHub.

If the GITHUB_TOKEN environment variable is set, it will be used for the API call to GitHub.

USAGE:
    crate.sh [FLAGS] [OPTIONS]

FLAGS:
    -f, --force    Force overwriting an existing binary
    -h, --help     Show this message and exit.

OPTIONS:
    --repo <SLUG>    Get the repository at "https://github/<SLUG>". [required]
    --to <PATH>      Where to install the binary. [required]
    --bin <NAME>     The binary to extract from the release tarball. [default: repository name]
    --tag <TAG>      The release version to install. [default: latest release]
    --target <ARCH>  Install the release compiled for <ARCH>. [default: current host]
EOF
}

usage_err() {
    usage
    1>&2 echo
    err "$@"
}

ok() {
    printf '\33[1;32minfo\33[0m: %s\n' "$1"
}

warn() {
    printf '\33[1;33mwarning\33[0m: %s\n' "$1"
}

err() {
    printf '\33[1;31merror\33[0m: %s\n' "$1" >&2
    exit 1
}

check_cmd() {
    command -v "$1" > /dev/null 2>&1
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "need '$1' (command not found)"
    fi
}

ensure() {
    if ! "$@"; then err "command failed: $*"; fi
}

# This wraps curl or wget. Try curl first, if not installed, use wget instead.
download() {
    local _url=$1; shift
    local _curl_arg
    local _dld

    if [ "${1-}" = "--progress" ]; then
        shift
        _curl_arg="--progress-bar"
    else
        _curl_arg="--silent"
    fi

    if check_cmd curl; then
        _dld=curl
    elif check_cmd wget; then
        _dld=wget
    else
        _dld='curl or wget'  # to be used in error message of need_cmd
    fi

    if [ "$_url" = --check ]; then
        need_cmd "$_dld"
    elif [ "$_dld" = curl ]; then
        curl $_curl_arg --proto '=https' --show-error --fail --location "$@" "$_url"
    elif [ "$_dld" = wget ]; then
        wget --no-verbose --https-only "$@" "$_url"
    else
        err "unknown downloader"  # should not reach here
    fi
}

_RELEASE_INFO=""

get_release_info() {
    local _repo=$1
    local _tag=$2
    local _url_suffix="latest"
    if [ "$_tag" != "latest" ]; then
        _url_suffix="tags/$_tag"
    fi
    local _url="https://api.github.com/repos/$_repo/releases/$_url_suffix"
    local _json

    if [ -z "$_RELEASE_INFO" ]; then
        if  [ -z "${GITHUB_TOKEN:-}" ]; then
            _json=$(download "$_url")
        else
            _json=$(download "$_url" --header "Authorization: Bearer $GITHUB_TOKEN")
        fi

        if test $? -ne 0; then
            err "failed to fetch $_tag release for repository '$_repo'"
        else
            _RELEASE_INFO="$_json"
        fi
    fi

    RETVAL="$_RELEASE_INFO"
}

get_tag() {
    local _repo=$1
    local _tag

    need_cmd grep
    need_cmd cut

    get_release_info "$_repo" "latest"
    _tag=$(echo "$RETVAL" | grep "tag_name" | cut -f 4 -d '"')

    RETVAL="$_tag"
}

get_release_assets() {
    local _repo=$1
    local _tag=$2
    local _targets

    need_cmd grep
    need_cmd cut

    get_release_info "$_repo" "$_tag"
    _targets=$(echo "$RETVAL" | grep 'name' | grep '.tar.gz"' | cut -f 4 -d '"')

    RETVAL="$_targets"
}

get_current_exe() {
    # Returns the executable used for system architecture detection
    # This is only run on Linux
    local _current_exe
    if test -L /proc/self/exe ; then
        _current_exe=/proc/self/exe
    else
        warn "Unable to find /proc/self/exe. System architecture detection might be inaccurate."
        if test -n "$SHELL" ; then
            _current_exe=$SHELL
        else
            need_cmd /bin/sh
            _current_exe=/bin/sh
        fi
        warn "Falling back to $_current_exe."
    fi
    echo "$_current_exe"
}

get_bitness() {
    need_cmd head
    # Architecture detection without dependencies beyond coreutils.
    # ELF files start out "\x7fELF", and the following byte is
    #   0x01 for 32-bit and
    #   0x02 for 64-bit.
    # The printf builtin on some shells like dash only supports octal
    # escape sequences, so we use those.
    local _current_exe=$1
    local _current_exe_head
    _current_exe_head=$(head -c 5 "$_current_exe")
    if [ "$_current_exe_head" = "$(printf '\177ELF\001')" ]; then
        echo 32
    elif [ "$_current_exe_head" = "$(printf '\177ELF\002')" ]; then
        echo 64
    else
        err "unknown platform bitness"
    fi
}

is_host_amd64_elf() {
    local _current_exe=$1

    need_cmd head
    need_cmd tail
    # ELF e_machine detection without dependencies beyond coreutils.
    # Two-byte field at offset 0x12 indicates the CPU,
    # but we're interested in it being 0x3E to indicate amd64, or not that.
    local _current_exe_machine
    _current_exe_machine=$(head -c 19 "$_current_exe" | tail -c 1)
    [ "$_current_exe_machine" = "$(printf '\076')" ]
}

get_endianness() {
    local _current_exe=$1
    local cputype=$2
    local suffix_eb=$3
    local suffix_el=$4

    # detect endianness without od/hexdump, like get_bitness() does.
    need_cmd head
    need_cmd tail

    local _current_exe_endianness
    _current_exe_endianness="$(head -c 6 "$_current_exe" | tail -c 1)"
    if [ "$_current_exe_endianness" = "$(printf '\001')" ]; then
        echo "${cputype}${suffix_el}"
    elif [ "$_current_exe_endianness" = "$(printf '\002')" ]; then
        echo "${cputype}${suffix_eb}"
    else
        err "unknown platform endianness"
    fi
}

get_architecture() {
    local _ostype _cputype _bitness _arch _clibtype
    _ostype="$(uname -s)"
    _cputype="$(uname -m)"
    _clibtype="gnu"

    if [ "$_ostype" = Linux ]; then
        if [ "$(uname -o)" = Android ]; then
            _ostype=Android
        fi
        if ldd --version 2>&1 | grep -q 'musl'; then
            _clibtype="musl"
        fi
    fi

    if [ "$_ostype" = Darwin ]; then
        # Darwin `uname -m` can lie due to Rosetta shenanigans. If you manage to
        # invoke a native shell binary and then a native uname binary, you can
        # get the real answer, but that's hard to ensure, so instead we use
        # `sysctl` (which doesn't lie) to check for the actual architecture.
        if [ "$_cputype" = i386 ]; then
            # Handling i386 compatibility mode in older macOS versions (<10.15)
            # running on x86_64-based Macs.
            # Starting from 10.15, macOS explicitly bans all i386 binaries from running.
            # See: <https://support.apple.com/en-us/HT208436>

            # Avoid `sysctl: unknown oid` stderr output and/or non-zero exit code.
            if sysctl hw.optional.x86_64 2> /dev/null || true | grep -q ': 1'; then
                _cputype=x86_64
            fi
        elif [ "$_cputype" = x86_64 ]; then
            # Handling x86-64 compatibility mode (a.k.a. Rosetta 2)
            # in newer macOS versions (>=11) running on arm64-based Macs.
            # Rosetta 2 is built exclusively for x86-64 and cannot run i386 binaries.

            # Avoid `sysctl: unknown oid` stderr output and/or non-zero exit code.
            if sysctl hw.optional.arm64 2> /dev/null || true | grep -q ': 1'; then
                _cputype=arm64
            fi
        fi
    fi

    if [ "$_ostype" = SunOS ]; then
        # Both Solaris and illumos presently announce as "SunOS" in "uname -s"
        # so use "uname -o" to disambiguate.  We use the full path to the
        # system uname in case the user has coreutils uname first in PATH,
        # which has historically sometimes printed the wrong value here.
        if [ "$(/usr/bin/uname -o)" = illumos ]; then
            _ostype=illumos
        fi

        # illumos systems have multi-arch userlands, and "uname -m" reports the
        # machine hardware name; e.g., "i86pc" on both 32- and 64-bit x86
        # systems.  Check for the native (widest) instruction set on the
        # running kernel:
        if [ "$_cputype" = i86pc ]; then
            _cputype="$(isainfo -n)"
        fi
    fi

    local _current_exe
    case "$_ostype" in

        Android)
            _ostype=linux-android
            ;;

        Linux)
            _current_exe=$(get_current_exe)
            _ostype=unknown-linux-$_clibtype
            _bitness=$(get_bitness "$_current_exe")
            ;;

        FreeBSD)
            _ostype=unknown-freebsd
            ;;

        NetBSD)
            _ostype=unknown-netbsd
            ;;

        DragonFly)
            _ostype=unknown-dragonfly
            ;;

        Darwin)
            _ostype=apple-darwin
            ;;

        illumos)
            _ostype=unknown-illumos
            ;;

        MINGW* | MSYS* | CYGWIN* | Windows_NT)
            _ostype=pc-windows-gnu
            ;;

        *)
            err "unrecognized OS type: $_ostype"
            ;;

    esac

    case "$_cputype" in

        i386 | i486 | i686 | i786 | x86)
            _cputype=i686
            ;;

        xscale | arm)
            _cputype=arm
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            fi
            ;;

        armv6l)
            _cputype=arm
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            else
                _ostype="${_ostype}eabihf"
            fi
            ;;

        armv7l | armv8l)
            _cputype=armv7
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            else
                _ostype="${_ostype}eabihf"
            fi
            ;;

        aarch64 | arm64)
            _cputype=aarch64
            ;;

        x86_64 | x86-64 | x64 | amd64)
            _cputype=x86_64
            ;;

        mips)
            _cputype=$(get_endianness "$_current_exe" mips '' el)
            ;;

        mips64)
            if [ "$_bitness" -eq 64 ]; then
                # only n64 ABI is supported for now
                _ostype="${_ostype}abi64"
                _cputype=$(get_endianness "$_current_exe" mips64 '' el)
            fi
            ;;

        ppc)
            _cputype=powerpc
            ;;

        ppc64)
            _cputype=powerpc64
            ;;

        ppc64le)
            _cputype=powerpc64le
            ;;

        s390x)
            _cputype=s390x
            ;;
        riscv64)
            _cputype=riscv64gc
            ;;
        *)
            err "unknown CPU type: $_cputype"
    esac

    # Detect 64-bit linux with 32-bit userland
    if [ "${_ostype}" = unknown-linux-gnu ] && [ "${_bitness}" -eq 32 ]; then
        case $_cputype in
            x86_64)
                if [ -n "${RUSTUP_CPUTYPE:-}" ]; then
                    _cputype="$RUSTUP_CPUTYPE"
                else
                    # 32-bit executable for amd64 = x32
                    if is_host_amd64_elf "$_current_exe"; then
                        err "\
                        This host is running an x32 userland, for which no native toolchain is provided.
                        You will have to install multiarch compatibility with i686 or amd64.
                        To do so, set the RUSTUP_CPUTYPE environment variable set to i686 or amd64 and re-run this script.
                        You will be able to add an x32 target after installation by running \`rustup target add x86_64-unknown-linux-gnux32\`.
                        "
                    else
                        _cputype=i686
                    fi
                fi
                ;;
            mips64)
                _cputype=$(get_endianness "$_current_exe" mips '' el)
                ;;
            powerpc64)
                _cputype=powerpc
                ;;
            aarch64)
                _cputype=armv7
                if [ "$_ostype" = "linux-android" ]; then
                    _ostype=linux-androideabi
                else
                    _ostype="${_ostype}eabihf"
                fi
                ;;
            riscv64gc)
                err "riscv64 with 32-bit userland unsupported"
                ;;
        esac
    fi

    # Detect armv7 but without the CPU features Rust needs in that build,
    # and fall back to arm.
    # See https://github.com/rust-lang/rustup.rs/issues/587.
    if [ "$_ostype" = "unknown-linux-gnueabihf" ] && [ "$_cputype" = armv7 ]; then
        if ! (ensure grep '^Features' /proc/cpuinfo | grep -E -q 'neon|simd') ; then
            # Either `/proc/cpuinfo` is malformed or unavailable, or
            # at least one processor does not have NEON (which is asimd on armv8+).
            _cputype=arm
        fi
    fi

    _arch="${_cputype}-${_ostype}"

    RETVAL="$_arch"
}

get_release_asset() {
    local _repo=$1
    local _tag=$2
    local _target=$3
    local _target_musl="${_target/gnu/musl}"
    local _avail_assets
    local _musl_avail

    get_release_assets "$_repo" "$_tag"
    read -r -a _avail_assets -d '' <<< "$RETVAL"

    for _asset in "${_avail_assets[@]}"; do
        if echo "$_asset" | grep -q "$_target"; then
            RETVAL="$_asset"
            return
        elif echo "$_asset" | grep -q "$_target_musl"; then
            _musl_avail="$_asset"
        fi
    done

    if [ -n "$_musl_avail" ]; then
        RETVAL="$_musl_avail"
        return
    else
        err "target $_target is not available for download"
    fi
}

main() {
    local _repo _name _bin _tag _target _dest _url _filename _td _tf _to
    local _force=false

    while test $# -gt 0; do
        case $1 in
            --force | -f)
                _force=true
                ;;
            --help | -h)
                usage
                exit 0
                ;;
            --repo)
                shift
                if [ -z "${1:-}" ]; then
                    usage_err "'--repo' option requires an argument"
                fi
                _repo=$1
                ;;
            --bin)
                shift
                if [ -z "${1:-}" ]; then
                    usage_err "'--bin' option requires an argument"
                fi
                _bin=$1
                ;;
            --tag)
                shift
                if [ -z "${1:-}" ]; then
                    usage_err "'--tag' option requires an argument"
                fi
                _tag=$1
                ;;
            --target)
                shift
                if [ -z "${1:-}" ]; then
                    usage_err "'--target' option requires an argument"
                fi
                _target=$1
                ;;
            --to)
                shift
                if [ -z "${1:-}" ]; then
                    usage_err "'--to' option requires an argument"
                fi
                _to=$1
                ;;
            *)
                ;;
        esac
        shift
    done

    need_cmd install
    need_cmd mkdir
    need_cmd mktemp
    need_cmd rm
    need_cmd tar

    download --check

    if [ -z "${_repo:-}" ]; then
        err "repository must be specified using '--repo'"
    fi

    if [ -z "${_to:-}" ]; then
        err "destination directory must be specified using '--to'"
    fi

    _name="${_repo#*/}"
    if [ -z "${_bin:-}" ]; then
        _bin=$_name
    fi

    _dest="$_to/$_bin"
    if [ -e "$_dest" ] && [ $_force = false ]; then
        err "$_dest already exists, use '-f' or '--force' to replace"
    fi

    if [ -z "${_tag:-}" ]; then
        get_tag "$_repo" || return 1
        _tag="$RETVAL"
        ok "latest release: $_tag"
    fi

    if [ -z "${_target:-}" ]; then
        get_architecture
        _target="$RETVAL"
        ok "detected target: $_target"
    fi

    get_release_asset "$_repo" "$_tag" "$_target"
    ok "found valid release asset: $RETVAL"
    _filename="$RETVAL"
    _url="https://github.com/$_repo/releases/download/$_tag/$_filename"
    _td=$(mktemp -d || mktemp -d -t tmp)
    trap "rm -rf '$_td'" EXIT

    ok "downloading: $_filename"
    if ! download "$_url" --progress | tar xz -C "$_td"; then
        err "failed to download and extract $_url"
    fi

    if [ -f "$_td/$_bin" ]; then
        _tf="$_td/$_bin"
    else
        for f in "$_td/$_name"*"/$_bin"; do
            _tf="$f"
        done
        if [ -z "$_tf" ]; then
            err "failed to find $_bin binary in artifact"
        fi
    fi

    if ! mkdir -p "$_to"; then
        err "failed to create $_to"
    fi

    if ! install -m 755 "$_tf" "$_dest"; then
        err "failed to install $_bin binary to $_dest"
    fi

    ok "installed: $_dest"
}

main "$@" || exit 1
