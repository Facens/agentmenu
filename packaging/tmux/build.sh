#!/bin/bash
# Builds the tmux AgentMenu ships: R17 says the user never installs, names or
# configures tmux, so the app carries its own, built from pinned sources.
#
#   packaging/tmux/build.sh        build (or restore from cache); the path of
#                                  the finished binary is the last stdout line
#
# KTD2: tmux 3.7c, static, with jemalloc forced on. The official macOS binary
# needs macOS 15 and is built without jemalloc, and a long-lived tmux server
# on macOS crashes in Apple's malloc on 3.6a-3.7b, every cited crash entering
# copy-mode, which `mouse on` reaches by scrolling. So this builds libevent,
# ncurses, utf8proc and jemalloc as static archives into a private prefix,
# links tmux against them with `--enable-jemalloc` passed explicitly (tmux's
# configure only warns about a missing jemalloc unless asked), and refuses to
# finish unless the result is what the plan says it is:
#
#   - arm64 (the app is Apple Silicon only, R30), minimum macOS 14.0 or lower
#   - links nothing but /usr/lib and /System (otool -L)
#   - jemalloc is in the binary, and so is /usr/share/terminfo, because a
#     static ncurses otherwise searches only its build prefix, which is gone
#     by the time a user runs it
#   - `-V` reports the pinned version
#
# Inputs are the tarballs named in sources.sha256, each checked against its
# SHA-256 before anything is unpacked, every time: a cached download is not
# trusted either. The output is cached outside git, keyed by that file and by
# this script, so changing either rebuilds and nothing else does:
#
#   .build/tmux/<key>/tmux        the binary
#   .build/tmux/<key>/VERSION     its version, e.g. 3.7c
#   .build/tmux/downloads/        the verified tarballs
#
# Environment (the last two exist so the tests can run this offline):
#   AM_TMUX_CACHE     cache root (default: <repo>/.build/tmux)
#   AM_TMUX_SOURCES   checksum file (default: packaging/tmux/sources.sha256)
#   AM_TMUX_KEEP_WORK keep the build tree after a successful build
#
# Bash 3.2 compatible: this runs on a stock macOS.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SOURCES="${AM_TMUX_SOURCES:-$HERE/sources.sha256}"
CACHE_ROOT="${AM_TMUX_CACHE:-$ROOT/.build/tmux}"
DOWNLOADS="$CACHE_ROOT/downloads"

# KTD2: build with this deployment target, so the binary runs on every macOS
# the app does. Raising it here is a decision about who can run the app.
DEPLOYMENT_TARGET="14.0"
COMPONENTS="tmux libevent ncurses utf8proc jemalloc"

log() { echo "tmux: $*" >&2; }
die() { echo "error: tmux build: $*" >&2; exit 1; }

[ -f "$SOURCES" ] || die "checksum file not found: $SOURCES"
[ "$(uname -s)" = "Darwin" ] || die "this builds the macOS helper; run it on a Mac"
[ "$(uname -m)" = "arm64" ] || die "this build is arm64 only (R30) and needs an Apple Silicon machine, not $(uname -m)"

# ---------------------------------------------------------------------------
# sources.sha256: one source per line, "<sha256>  <file name>  <url>". Blank
# lines and # comments are ignored. A component is found by its file name's
# leading word ("tmux-3.7c.tar.gz" -> tmux), and each must appear exactly once.
source_field() { # <component> <1=hash|2=file|3=url>
    awk -v c="$1" -v n="$2" '
        /^[[:space:]]*(#|$)/ { next }
        index($2, c "-") == 1 && substr($2, length(c) + 2, 1) ~ /[0-9]/ { print $n }
    ' "$SOURCES"
}

for component in $COMPONENTS; do
    count="$(source_field "$component" 2 | wc -l | tr -d ' ')"
    [ "$count" -eq 1 ] || die "$SOURCES lists $count sources for $component, expected exactly 1"
done

version_of() { # tmux-3.7c.tar.gz -> 3.7c
    source_field "$1" 2 | sed -e "s/^$1-//" -e 's/\.tar\.[a-z0-9]*$//'
}
TMUX_VERSION="$(version_of tmux)"

# ---------------------------------------------------------------------------
# Cache key: this file and the checksum file. Either changing is a different
# build, and the key is what CI hashes too (see .github/workflows/ci.yml).
KEY="$(cat "$SOURCES" "${BASH_SOURCE[0]}" | shasum -a 256 | cut -c1-16)"
OUT="$CACHE_ROOT/$KEY"
BINARY="$OUT/tmux"

# ---------------------------------------------------------------------------
# The checks that make this "tmux as the plan describes it". They run on a
# fresh build and again on a cache hit: a restored cache is only as good as
# what it still verifies.
minos_of() { # the LC_BUILD_VERSION minimum OS, e.g. 14.0
    otool -l "$1" | awk '/cmd LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }'
}

version_le() { # <a> <b>: is a <= b, comparing dotted numbers
    local IFS=. a b i
    read -r -a a <<< "$1"
    read -r -a b <<< "$2"
    for i in 0 1 2; do
        if [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]; then return 0; fi
        if [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]; then return 1; fi
    done
    return 0
}

verify_binary() { # <binary> <build tree to forbid in the binary, or "">
    local bin="$1" work="$2" archs minos bad strings_out
    [ -x "$bin" ] || die "$bin is missing or not executable"

    archs="$(lipo -archs "$bin")"
    [ "$archs" = "arm64" ] || die "architecture is '$archs', expected arm64"

    minos="$(minos_of "$bin")"
    [ -n "$minos" ] || die "no LC_BUILD_VERSION in $bin"
    version_le "$minos" "$DEPLOYMENT_TARGET" || die "minimum macOS is $minos, expected $DEPLOYMENT_TARGET or lower"

    # Every dependency is a system library. otool -L's first line is the file
    # itself, so it is skipped; a static build has nothing else but libSystem.
    bad="$(otool -L "$bin" | tail -n +2 | awk '{ print $1 }' | grep -vE '^(/usr/lib/|/System/)' || true)"
    [ -z "$bad" ] || die "links non-system libraries: $(echo "$bad" | tr '\n' ' ')"

    # A weak import is a symbol newer than the deployment target that the
    # binary calls without checking; on a Mac that lacks it, it is a null call.
    # jemalloc's zone hook names _malloc_default_purgeable_zone weakly and
    # tests it for null before use; that one is expected.
    bad="$(nm -m "$bin" | grep '(undefined) weak external' | grep -v '_malloc_default_purgeable_zone ' || true)"
    [ -z "$bad" ] || die "weak imports (newer than macOS $DEPLOYMENT_TARGET): $(echo "$bad" | tr -s ' ' | tr '\n' ';')"

    strings_out="$(strings -a "$bin")"
    grep -qi 'jemalloc' <<< "$strings_out" || die "jemalloc is not in the binary (KTD2)"
    grep -qF 'jemalloc_zone' <<< "$strings_out" || die "jemalloc's malloc-zone hook is not linked in; memory from the C library would be freed by the wrong allocator"
    grep -qF '/usr/share/terminfo' <<< "$strings_out" || die "/usr/share/terminfo is not in the binary; a static ncurses would look only in its build prefix"
    if [ -n "$work" ] && grep -qF "$work" <<< "$strings_out"; then
        die "the build directory $work is embedded in the binary"
    fi

    [ "$("$bin" -V)" = "tmux $TMUX_VERSION" ] || die "'tmux -V' reports '$("$bin" -V)', expected 'tmux $TMUX_VERSION'"

    smoke_test "$bin"
}

# `-V` proves the binary starts; it does not prove it works (a call through a
# null pointer in libevent's startup passed it). So run a real server, on a
# private socket under /tmp (a socket path has to fit in 104 bytes, so not a
# deep one), make a session, and read from its debug log which libraries it
# really runs with: the log names what the binary was compiled against, which
# is how a header taken from the SDK instead of the pinned source shows up.
smoke_test() { # <binary>
    local bin="$1" dir log
    dir="$(mktemp -d /tmp/amtmux.XXXXXX)"
    (
        cd "$dir"
        trap '"$bin" -S "$dir/s" kill-server >/dev/null 2>&1 || true' EXIT
        export TERM=xterm-256color
        "$bin" -vv -S "$dir/s" -f /dev/null new-session -d 'sleep 30' || die "the server did not start"
        "$bin" -S "$dir/s" list-sessions >/dev/null || die "the server does not answer on its socket"
    ) || { rm -rf "$dir"; exit 1; }
    log="$(cat "$dir"/tmux-server-*.log 2>/dev/null || true)"
    rm -rf "$dir"
    local component expected
    for component in libevent ncurses utf8proc jemalloc; do
        expected="$(version_of "$component")"
        # "using libevent 2.1.12-stable select", "using ncurses 6.5 20240427",
        # "using jemalloc 5.3.0-0-g...": the version, followed by anything.
        grep -qE "using $component $expected( |-|\$)" <<< "$log" \
            || die "the server runs with a different $component than the pinned $expected: $(grep "using $component" <<< "$log" | head -1)"
    done
}

# One key at a time. A build for other sources or another script is a stale
# build, and leaving it around invites something that scans the cache for "a
# tmux" to pick it up. Only this script's own entries are removed: 16 hex
# characters, and the downloads, which are verified on every use anyway.
prune_stale() {
    local entry
    for entry in "$CACHE_ROOT"/*; do
        [ -d "$entry" ] || continue
        case "$(basename "$entry")" in
            "$KEY"|"$KEY.work"|downloads) ;;
            ????????????????|????????????????.work) rm -rf "$entry" ;;
        esac
    done
}

if [ -x "$BINARY" ] && [ -f "$OUT/VERSION" ]; then
    verify_binary "$BINARY" ""
    prune_stale
    log "cached build $KEY, tmux $TMUX_VERSION"
    echo "$BINARY"
    exit 0
fi

# ---------------------------------------------------------------------------
# Download and verify, all five, before anything is built.
mkdir -p "$DOWNLOADS"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

fetch() { # <component>: leaves a checksum-verified tarball in $DOWNLOADS
    local component="$1" want file url path got
    want="$(source_field "$component" 1)"
    file="$(source_field "$component" 2)"
    url="$(source_field "$component" 3)"
    path="$DOWNLOADS/$file"

    if [ -f "$path" ] && [ "$(sha256_of "$path")" = "$want" ]; then
        return 0
    fi
    # Missing, or present and wrong: fetch it again rather than trust it.
    rm -f "$path"
    log "downloading $file"
    curl --fail --silent --show-error --location --retry 3 --output "$path.part" "$url" \
        || { rm -f "$path.part"; die "could not download $url"; }
    got="$(sha256_of "$path.part")"
    if [ "$got" != "$want" ]; then
        rm -f "$path.part"
        die "checksum mismatch for $file: expected $want, got $got (from $url)"
    fi
    mv -f "$path.part" "$path"
}

for component in $COMPONENTS; do
    fetch "$component"
done

# ---------------------------------------------------------------------------
# Build. Everything lands in one private prefix, which is deleted afterwards
# and which the binary must not depend on or mention.
WORK="$OUT.work"
PREFIX="$WORK/prefix"
SRC="$WORK/src"
rm -rf "$WORK" "$OUT"
mkdir -p "$PREFIX/lib" "$PREFIX/include" "$SRC"
cleanup() { [ -n "${AM_TMUX_KEEP_WORK:-}" ] || rm -rf "$WORK"; }
trap cleanup EXIT

JOBS="$(sysctl -n hw.ncpu)"

# arm64 only, one deployment target, no embedded build paths.
#
# The SDK is newer than the target (14.0), and the two disagree about what
# exists: configure asks "does pipe2 link?", the new SDK says yes, and libevent
# then calls a function that does not exist on older macOS, through a weak
# import, so the call is through a null pointer (it did, on first start).
# -Werror=unguarded-availability-new fails the compile of any source that
# calls such a function without a guard, and names it. configure's own
# link-only checks cannot see availability at all, so the functions that error
# names are answered "no" by hand where they are configured below, and
# verify_binary refuses a binary with any weak import it does not know.
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export ZERO_AR_DATE=1
CFLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -O2 -Werror=unguarded-availability-new -ffile-prefix-map=$WORK=."
export CFLAGS
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-arch arm64 -mmacosx-version-min=$DEPLOYMENT_TARGET -L$PREFIX/lib"
# Never read Homebrew's or anyone else's libraries: pkg-config sees this
# prefix and nothing else (tmux's configure is told the same things directly
# below, so a machine without pkg-config builds identically).
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

unpack() { # <component>: unpacks into $SRC and prints the directory
    local file
    file="$(source_field "$1" 2)"
    tar -xf "$DOWNLOADS/$file" -C "$SRC"
    echo "$SRC/$(echo "$file" | sed 's/\.tar\.[a-z0-9]*$//')"
}

# A dynamic library next to a static one wins the linker's pick. Removing
# them makes "static" a fact about the prefix, not a hope about linker flags.
drop_dylibs() { rm -f "$PREFIX"/lib/*.dylib; }

build_libevent() {
    local dir; dir="$(unpack libevent)"
    log "libevent"
    ( cd "$dir"
      # ac_cv_func_pipe2=no: configure's link test cannot see availability
      # (see the CFLAGS note), so it finds the SDK's pipe2 and libevent calls
      # it. It postdates macOS 14, where libevent's pipe()+fcntl fallback is
      # what runs.
      ./configure --prefix="$PREFIX" --disable-shared --enable-static \
          --disable-openssl --disable-libevent-regress --disable-samples \
          ac_cv_func_pipe2=no >"$WORK/libevent.log" 2>&1
      make -j"$JOBS" >>"$WORK/libevent.log" 2>&1
      make install >>"$WORK/libevent.log" 2>&1 ) || { tail -40 "$WORK/libevent.log" >&2; die "libevent failed"; }
    drop_dylibs
}

build_ncurses() {
    local dir; dir="$(unpack ncurses)"
    log "ncurses"
    # The terminfo database is the system's, not ours: /usr/share/terminfo is
    # both the default directory and the only one searched.
    ( cd "$dir"
      ./configure --prefix="$PREFIX" --without-shared --with-normal --without-debug \
          --without-ada --without-cxx --without-cxx-binding --without-manpages --without-tests \
          --without-progs --disable-lib-suffixes --disable-db-install --with-termlib \
          --with-default-terminfo-dir=/usr/share/terminfo \
          --with-terminfo-dirs=/usr/share/terminfo >"$WORK/ncurses.log" 2>&1
      make -j"$JOBS" >>"$WORK/ncurses.log" 2>&1
      make install.libs install.includes >>"$WORK/ncurses.log" 2>&1 ) || { tail -40 "$WORK/ncurses.log" >&2; die "ncurses failed"; }
    drop_dylibs
}

build_utf8proc() {
    local dir; dir="$(unpack utf8proc)"
    log "utf8proc"
    ( cd "$dir"
      make -j"$JOBS" libutf8proc.a >"$WORK/utf8proc.log" 2>&1
      cp libutf8proc.a "$PREFIX/lib/" && cp utf8proc.h "$PREFIX/include/" ) || { tail -40 "$WORK/utf8proc.log" >&2; die "utf8proc failed"; }
}

build_jemalloc() {
    local dir; dir="$(unpack jemalloc)"
    log "jemalloc"
    ( cd "$dir"
      # An empty prefix: on macOS jemalloc defaults to "je_", and tmux calls
      # plain mallctl. Unprefixed, jemalloc also defines malloc and free
      # itself, so the static link replaces Apple's allocator in tmux's own
      # calls, and its zone hook takes over the library's.
      ./configure --prefix="$PREFIX" --disable-shared --disable-cxx --with-jemalloc-prefix= >"$WORK/jemalloc.log" 2>&1
      make -j"$JOBS" build_lib_static >>"$WORK/jemalloc.log" 2>&1
      make install_lib_static install_include >>"$WORK/jemalloc.log" 2>&1 ) || { tail -40 "$WORK/jemalloc.log" >&2; die "jemalloc failed"; }
    drop_dylibs
}

build_tmux() {
    local dir; dir="$(unpack tmux)"
    log "tmux $TMUX_VERSION"
    # ncurses installs its headers in include/ncurses, and the SDK has its own
    # (6.0, from 2015) on the default path: without that -I the compile finds
    # the SDK's and the link finds ours.
    # --enable-jemalloc is explicit on purpose (KTD2): without it tmux's
    # configure decides for itself. Passed this way it is an error to not find
    # jemalloc, which is the point. The library variables are given directly
    # rather than found through pkg-config.
    #
    # -force_load is not decoration. jemalloc's zone.o (the part that makes it
    # macOS's default malloc zone, so memory the C library allocates for tmux
    # is freed by the allocator that made it) is referenced by nothing, so a
    # plain static link leaves it out. The binary then links, and aborts in
    # free() in its first second: tmux frees what vasprintf allocated.
    ( cd "$dir"
      ./configure --prefix="$PREFIX" \
          --enable-jemalloc --enable-utf8proc \
          LIBEVENT_CORE_CFLAGS="-I$PREFIX/include" LIBEVENT_CORE_LIBS="$PREFIX/lib/libevent_core.a" \
          LIBEVENT_CFLAGS="-I$PREFIX/include" LIBEVENT_LIBS="$PREFIX/lib/libevent.a" \
          LIBTINFO_CFLAGS="-I$PREFIX/include/ncurses" LIBTINFO_LIBS="$PREFIX/lib/libtinfo.a" \
          LIBNCURSES_CFLAGS="-I$PREFIX/include/ncurses" LIBNCURSES_LIBS="$PREFIX/lib/libncurses.a" \
          LIBUTF8PROC_CFLAGS="-I$PREFIX/include" LIBUTF8PROC_LIBS="$PREFIX/lib/libutf8proc.a" \
          JEMALLOC_CFLAGS="-I$PREFIX/include" JEMALLOC_LIBS="-Wl,-force_load,$PREFIX/lib/libjemalloc.a" \
          >"$WORK/tmux.log" 2>&1
      # tmux has no config.h: its configure puts the switches on the compiler
      # command line, so that is where they are checked.
      grep -q -- '-DHAVE_JEMALLOC' Makefile || { echo "configure did not enable HAVE_JEMALLOC" >>"$WORK/tmux.log"; exit 1; }
      grep -q -- '-DHAVE_UTF8PROC' Makefile || { echo "configure did not enable HAVE_UTF8PROC" >>"$WORK/tmux.log"; exit 1; }
      make -j"$JOBS" >>"$WORK/tmux.log" 2>&1
      cp tmux "$WORK/tmux" ) || { tail -40 "$WORK/tmux.log" >&2; die "tmux failed"; }
}

started="$(date +%s)"
build_libevent
build_ncurses
build_utf8proc
build_jemalloc
build_tmux

# Strip local symbols (the signature goes with them, and an unsigned arm64
# binary will not run, so sign it again ad-hoc; bundle.sh signs it properly).
strip -x "$WORK/tmux"
codesign --force --sign - --timestamp=none "$WORK/tmux" 2>/dev/null

verify_binary "$WORK/tmux" "$WORK"

# Finished: only now does the cache entry exist, so a failed or interrupted
# build can never leave a half-made one behind.
mkdir -p "$OUT"
cp "$WORK/tmux" "$BINARY.part" && mv -f "$BINARY.part" "$BINARY"
echo "$TMUX_VERSION" > "$OUT/VERSION"
prune_stale
log "built tmux $TMUX_VERSION in $(( $(date +%s) - started ))s, $(stat -f %z "$BINARY") bytes, cache $KEY"
echo "$BINARY"
