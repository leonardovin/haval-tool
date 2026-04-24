#!/usr/bin/env bash
# Test harness for install.sh. Stubs every external binary used by the script
# so we can run it on a developer laptop (no Haval device required) and assert
# which APK URL the script fetched.
#
# Usage: scripts/test_install_sh.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SH="$REPO_ROOT/install.sh"

if [ ! -f "$INSTALL_SH" ]; then
    echo "FAIL: could not find $INSTALL_SH" >&2
    exit 2
fi

# -------- Stub factory --------
make_stubs() {
    local stub_dir="$1"
    mkdir -p "$stub_dir"

    # curl: if called with the GitHub API, emit a fake releases JSON; otherwise
    # just create an empty file at -o <path> so download() sees a non-empty file.
    cat >"$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
# Log every invocation for later assertions.
echo "curl $*" >>"$STUB_LOG"
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -s|-L|--progress-bar) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    *api.github.com/repos/*/releases/latest*)
        # Emit pretty-printed JSON so install.sh's `grep | cut -d\" -f4` extracts
        # the URL on field 4 (same shape as the real GitHub API response).
        cat <<'JSON'
{
  "assets": [
    {
      "browser_download_url": "https://fake-latest/app.apk"
    }
  ]
}
JSON
        ;;
    *)
        if [ -n "$out" ]; then
            echo "fake-download:$url" >"$out"
        else
            echo "fake-download:$url"
        fi
        ;;
esac
STUB
    chmod +x "$stub_dir/curl"

    # Trivial success stubs.
    for cmd in pm chmod setsid pkill rm; do
        cat >"$stub_dir/$cmd" <<STUB
#!/usr/bin/env bash
echo "$cmd \$*" >>"\$STUB_LOG"
exit 0
STUB
        chmod +x "$stub_dir/$cmd"
    done

    # pgrep: install.sh checks fridaserver. Return success so it treats it as running.
    cat >"$stub_dir/pgrep" <<'STUB'
#!/usr/bin/env bash
echo "pgrep $*" >>"$STUB_LOG"
exit 0
STUB
    chmod +x "$stub_dir/pgrep"

    # pidof: return a fake PID for system_server.
    cat >"$stub_dir/pidof" <<'STUB'
#!/usr/bin/env bash
echo "pidof $*" >>"$STUB_LOG"
echo 1234
exit 0
STUB
    chmod +x "$stub_dir/pidof"

    # fridainject: install.sh runs `./fridainject ...`. We don't need it; create
    # a local executable that just exits 0. Dropped into the working dir at test
    # time, not into PATH.
    :
}

# -------- Runner --------
# $1: label, $2: env-vars to export (as a `key=val key=val` string), $3: expected
# URL to find in the curl log.
run_case() {
    local label="$1"
    local env_vars="$2"
    local expected_url="$3"
    local unexpected_url="${4:-}"
    # Optional: the exact URL the `-o haval.apk` curl call must have used.
    local expected_haval_url="${5:-$expected_url}"

    local workdir
    workdir="$(mktemp -d)"
    local stub_dir="$workdir/stubs"
    make_stubs "$stub_dir"

    # Drop a fake fridainject in the workdir (install.sh cd's to . and invokes it).
    cat >"$workdir/fridainject" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$workdir/fridainject"
    # Make fridaserver look executable too (test -x ./fridaserver).
    cat >"$workdir/fridaserver" <<'EOF'
#!/usr/bin/env bash
sleep 0.1
EOF
    chmod +x "$workdir/fridaserver"

    export STUB_LOG="$workdir/stub.log"
    : >"$STUB_LOG"

    # Run install.sh in the workdir with PATH prefixed by stubs.
    (
        cd "$workdir"
        # shellcheck disable=SC2086
        env PATH="$stub_dir:$PATH" $env_vars sh "$INSTALL_SH"
    ) >"$workdir/run.out" 2>&1
    local rc=$?

    if [ $rc -ne 0 ]; then
        echo "FAIL [$label]: install.sh exited $rc"
        echo "--- run output ---"
        cat "$workdir/run.out"
        echo "--- curl log ---"
        grep '^curl ' "$STUB_LOG" || true
        return 1
    fi

    if ! grep -q "$expected_url" "$STUB_LOG"; then
        echo "FAIL [$label]: expected curl to hit '$expected_url'"
        echo "--- curl log ---"
        grep '^curl ' "$STUB_LOG" || true
        return 1
    fi

    if [ -n "$unexpected_url" ] && grep -q "$unexpected_url" "$STUB_LOG"; then
        echo "FAIL [$label]: curl unexpectedly hit '$unexpected_url'"
        grep '^curl ' "$STUB_LOG"
        return 1
    fi

    # --- Stronger assertion: the `-o haval.apk` download call used exactly the
    # expected URL, AND the file written by curl matches that URL. This catches
    # regressions where HAVAL_APK_URL is ignored and the latest-release fallback
    # silently writes the wrong APK.
    local haval_line
    haval_line="$(grep -E '^curl .* -o haval\.apk ' "$STUB_LOG" | tail -n1)"
    if [ -z "$haval_line" ]; then
        echo "FAIL [$label]: install.sh never ran \`curl -o haval.apk <url>\`"
        grep '^curl ' "$STUB_LOG" || true
        return 1
    fi
    # The URL is the last whitespace-separated token on that line.
    local haval_called_url
    haval_called_url="${haval_line##* }"
    if [ "$haval_called_url" != "$expected_haval_url" ]; then
        echo "FAIL [$label]: haval.apk was downloaded from '$haval_called_url', expected '$expected_haval_url'"
        return 1
    fi
    # The curl stub writes "fake-download:<url>" into -o <file>; check the file
    # content matches.
    if [ ! -f "$workdir/haval.apk" ]; then
        echo "FAIL [$label]: haval.apk file was not written"
        return 1
    fi
    if ! grep -qxF "fake-download:$expected_haval_url" "$workdir/haval.apk"; then
        echo "FAIL [$label]: haval.apk content does not match '$expected_haval_url'"
        echo "--- haval.apk content ---"
        cat "$workdir/haval.apk"
        return 1
    fi

    echo "PASS [$label] (haval.apk <- $haval_called_url)"
    return 0
}

fails=0

# Case 1: no pinning → haval.apk must come from the github latest URL (our stub
# returns https://fake-latest/app.apk for that).
run_case "unpinned uses latest release" "" "https://fake-latest/app.apk" || fails=$((fails+1))

# Case 2: HAVAL_APK_URL set → must be used; must NOT hit the github API for
# bobaoapae/haval-app-tool-multimidia.
run_case "pinned URL overrides latest" \
    "HAVAL_APK_URL=https://pinned.example/custom-v9.apk" \
    "https://pinned.example/custom-v9.apk" \
    "bobaoapae/haval-app-tool-multimidia" \
    || fails=$((fails+1))

if [ $fails -ne 0 ]; then
    echo ""
    echo "$fails test(s) failed."
    exit 1
fi

echo ""
echo "All install.sh tests passed."
