#!/bin/sh
# End-to-end test runner: compile each test/cases/*.c and compare fat output
# with test/expected/*.out and optional .exit / .stdin files.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p test/tmp

if ! make -s all >/dev/null 2>test/tmp/make.err; then
    echo "BUILD FAILED"
    cat test/tmp/make.err 2>/dev/null || true
    exit 1
fi

mkdir -p test/tmp
FAIL=0
COUNT=0
for c in test/cases/*.c; do
    name="$(basename "$c" .c)"
    COUNT=$((COUNT + 1))
    fc="test/tmp/$name.fc"
    if ! ./bin/fatcc "$c" -o "$fc" >test/tmp/$name.cc 2>test/tmp/$name.cerr; then
        echo "FAIL compile $name"
        sed 's/^/    /' test/tmp/$name.cerr
        FAIL=1
        continue
    fi
    stdin_file="test/cases/$name.stdin"
    if [ -f "$stdin_file" ]; then
        ./bin/fat "$fc" >test/tmp/$name.actual 2>test/tmp/$name.rterr <"$stdin_file"
    else
        ./bin/fat "$fc" >test/tmp/$name.actual 2>test/tmp/$name.rterr </dev/null
    fi
    rc=$?
    expected_exit=0
    [ -f "test/expected/$name.exit" ] && expected_exit="$(cat test/expected/$name.exit)"
    if [ "$rc" -ne "$expected_exit" ]; then
        echo "FAIL exit $name: got $rc want $expected_exit"
        sed 's/^/    /' test/tmp/$name.rterr
        FAIL=1
        continue
    fi
    if ! diff -q "test/expected/$name.out" "test/tmp/$name.actual" >/dev/null; then
        echo "FAIL output $name"
        diff "test/expected/$name.out" "test/tmp/$name.actual" | sed 's/^/    /'
        FAIL=1
        continue
    fi
    echo "PASS $name"
done
echo "----"
echo "$COUNT test(s), $([ $FAIL -eq 0 ] && echo OK || echo FAILED)"
exit $FAIL
