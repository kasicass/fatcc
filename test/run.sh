#!/bin/sh
# End-to-end test runner: compile each test/cases/*.c at -O0 and -O1 and compare
# fat output with test/expected/*.out and an optional .exit file.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p test/tmp

if ! make -s all >/dev/null 2>test/tmp/make.err; then
    echo "BUILD FAILED"
    cat test/tmp/make.err 2>/dev/null || true
    exit 1
fi

FAIL=0
COUNT=0
for c in test/cases/*.c; do
    name="$(basename "$c" .c)"
    for opt in -O0 -O1; do
        COUNT=$((COUNT + 1))
        tag="$name$opt"
        fc="test/tmp/$tag.fc"
        if ! ./bin/fatcc "$opt" "$c" -o "$fc" >"test/tmp/$tag.cc" 2>"test/tmp/$tag.cerr"; then
            echo "FAIL compile $name ($opt)"
            sed 's/^/    /' "test/tmp/$tag.cerr"
            FAIL=1
            continue
        fi
        stdin_file="test/cases/$name.stdin"
        if [ -f "$stdin_file" ]; then
            ./bin/fat "$fc" >"test/tmp/$tag.actual" 2>"test/tmp/$tag.rterr" <"$stdin_file"
        else
            ./bin/fat "$fc" >"test/tmp/$tag.actual" 2>"test/tmp/$tag.rterr" </dev/null
        fi
        rc=$?
        expected_exit=0
        [ -f "test/expected/$name.exit" ] && expected_exit="$(cat test/expected/$name.exit)"
        if [ "$rc" -ne "$expected_exit" ]; then
            echo "FAIL exit $name ($opt): got $rc want $expected_exit"
            sed 's/^/    /' "test/tmp/$tag.rterr"
            FAIL=1
            continue
        fi
        if ! diff -q "test/expected/$name.out" "test/tmp/$tag.actual" >/dev/null; then
            echo "FAIL output $name ($opt)"
            diff "test/expected/$name.out" "test/tmp/$tag.actual" | sed 's/^/    /'
            FAIL=1
            continue
        fi
        echo "PASS $name ($opt)"
    done
done

echo "----"
echo "$COUNT test(s), $([ $FAIL -eq 0 ] && echo OK || echo FAILED)"
exit $FAIL
