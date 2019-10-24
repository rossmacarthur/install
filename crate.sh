#!/bin/bash

# This is just a little script that can be downloaded from the internet to
# install a Rust crate from a GitHub release. It determines the latest release,
# the current platform (without the need for `rustc`), and installs the
# extracted binary to the specified location.

usage() {
    cat 1>&2 <<EOF
Install a binary release of a Rust crate hosted on GitHub.

USAGE:
    crate.sh [FLAGS] [OPTIONS]

FLAGS:
    -f, --force    Force overwriting an existing binary
    -h, --help     Show this message and exit.
    -V, --version  Show the version and exit.

OPTIONS:
        --repo <SLUG>      Get the repository at "https://github/<SLUG>".
        --bin <NAME>       The binary to extract from the release tarball. [default: repository name]
        --tag <TAG>        The release version to install. [default: latest release]
        --target <TARGET>  Install the release compiled for <TARGET>. [default: current host]
        --to <LOCATION>    Where to install the binary. [default: current directory]
EOF
}

ok() {
    printf '\33[1;32minfo:\33[0m %s\n' "$1"
}

err() {
    printf '\33[1;31merror:\33[0m %s\n' "$1" >&2
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

# This wraps curl or wget. Try curl first, if not installed, use wget instead.
download() {
    local _url=$1
    local _dld

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
        curl --silent --proto '=https' --show-error --fail --location "$_url"
    elif [ "$_dld" = wget ]; then
        wget --no-verbose --https-only "$_url"
    else
        err "unknown downloader"  # should not reach here
    fi
}

get_tag() {
    local _json
    local _repo=$1
    local _url="https://api.github.com/repos/$_repo/releases/latest"

    need_cmd grep
    need_cmd cut

    _json=$(download "$_url")

    if test $? -ne 0; then
        err "failed to determine latest release for repository '$_repo'"
    fi

    _tag=$(echo "$_json" | grep "tag_name" | cut -f 4 -d '"')

    RETVAL="$_tag"
}

get_bitness() {
    need_cmd head
    # Architecture detection without dependencies beyond coreutils.
    # ELF files start out "\x7fELF", and the following byte is
    #   0x01 for 32-bit and
    #   0x02 for 64-bit.
    # The printf builtin on some shells like dash only supports octal
    # escape sequences, so we use those.
    local _current_exe_head
    _current_exe_head=$(head -c 5 /proc/self/exe )
    if [ "$_current_exe_head" = "$(printf '\177ELF\001')" ]; then
        echo 32
    elif [ "$_current_exe_head" = "$(printf '\177ELF\002')" ]; then
        echo 64
    else
        err "unknown platform bitness"
    fi
}

get_endianness() {
    local cputype=$1
    local suffix_eb=$2
    local suffix_el=$3

    # detect endianness without od/hexdump, like get_bitness() does.
    need_cmd head
    need_cmd tail

    local _current_exe_endianness
    _current_exe_endianness="$(head -c 6 /proc/self/exe | tail -c 1)"
    if [ "$_current_exe_endianness" = "$(printf '\001')" ]; then
        echo "${cputype}${suffix_el}"
    elif [ "$_current_exe_endianness" = "$(printf '\002')" ]; then
        echo "${cputype}${suffix_eb}"
    else
        err "unknown platform endianness"
    fi
}

get_target() {
    local _ostype _cputype _bitness _target _clibtype

    need_cmd uname

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

    if [ "$_ostype" = Darwin ] && [ "$_cputype" = i386 ]; then
        # Darwin `uname -m` lies
        if sysctl hw.optional.x86_64 | grep -q ': 1'; then
            _cputype=x86_64
        fi
    fi

    case "$_ostype" in

        Android)
            _ostype=linux-android
            ;;

        Linux)
            _ostype=unknown-linux-$_clibtype
            _bitness=$(get_bitness)
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

        MINGW* | MSYS* | CYGWIN*)
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

        aarch64)
            _cputype=aarch64
            ;;

        x86_64 | x86-64 | x64 | amd64)
            _cputype=x86_64
            ;;

        mips)
            _cputype=$(get_endianness mips '' el)
            ;;

        mips64)
            if [ "$_bitness" -eq 64 ]; then
                # only n64 ABI is supported for now
                _ostype="${_ostype}abi64"
                _cputype=$(get_endianness mips64 '' el)
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

        *)
            err "unknown CPU type: $_cputype"

    esac

    # Detect 64-bit linux with 32-bit userland
    if [ "${_ostype}" = unknown-linux-gnu ] && [ "${_bitness}" -eq 32 ]; then
        case $_cputype in
            x86_64)
                _cputype=i686
                ;;
            mips64)
                _cputype=$(get_endianness mips '' el)
                ;;
            powerpc64)
                _cputype=powerpc
                ;;
        esac
    fi

    # Detect armv7 but without the CPU features Rust needs in that build,
    # and fall back to arm.
    # See https://github.com/rust-lang/rustup.rs/issues/587.
    if [ "$_ostype" = "unknown-linux-gnueabihf" ] && [ "$_cputype" = armv7 ]; then
        if grep '^Features' /proc/cpuinfo | grep -q -v neon; then
            # At least one processor does not have NEON.
            _cputype=arm
        fi
    fi

    _target="${_cputype}-${_ostype}"

    RETVAL="$_target"
}

main() {
    local _repo _bin _tag _target _dest _url _filename _td
    local _force=false
    local _to

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
                _repo=$2
                shift
                ;;
            --bin)
                _bin=$2
                shift
                ;;
            --tag)
                _tag=$2
                shift
                ;;
            --target)
                _target=$2
                shift
                ;;
            --to)
                _to=$2
                shift
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

    if [ -z "$_repo" ]; then
        err "repository must be specified using '--repo'"
    fi

    if [ -z "$_to" ]; then
        err "destination directory must be specified using '--to'"
    fi

    if [ -z "$_bin" ]; then
        _bin="${_repo#*/}"
    fi

    _dest="$_to/$_bin"
    if [ -e "$_dest" ] && [ $_force = false ]; then
        err "$_dest already exists, use '--force' to replace"
    fi

    if [ -z "$_tag" ]; then
        get_tag "$_repo" || return 1
        _tag="$RETVAL"
        ok "latest release: $_tag"
    fi

    if [ -z "$_target" ]; then
        get_target || return 1
        _target="$RETVAL"
        ok "detected target: $_target"
    fi

    _filename="$_bin-$_tag-$_target.tar.gz"
    _url="https://github.com/$_repo/releases/download/$_tag/$_filename"
    _td=$(mktemp -d || mktemp -d -t tmp)

    ok "downloading: $_filename"
    if ! download "$_url" | tar xz -C "$_td" "$_bin"; then
        err "failed to download $_url"
    fi
    if ! mkdir -p "$_to"; then
        err "failed to create $_to"
    fi
    if ! install -m 755 "$_td/$_bin" "$_dest"; then
        err "failed to install $_bin in $_dest"
    fi
    rm -rf "$_td"
    ok "installed: $_dest"
}

main "$@" || exit 1
