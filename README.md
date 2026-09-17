# fatcc / fat

A C compiler (`fatcc`) and bytecode runtime (`fat`) implemented in pure Erlang/OTP.

```
$ fatcc hello.c -o hello.fc
$ fat hello.fc
hello, world
```

- `fatcc` compiles C source into a self-describing bytecode image (`.fc`).
- `fat` loads and interprets `.fc` files.

Design: see [`doc/design.md`](doc/design.md).

## Build

```
make            # compiles into ebin/, installs bin/fatcc and bin/fat wrappers
make test       # runs the end-to-end test suite
```

Requires Erlang/OTP 28+.

## Usage

```
fatcc [options] file.c ...
  -o <file>      output .fc
  -I <dir>       add include search directory
  -D<name>[=v]   predefine macro
  -E             preprocess only
  -S             emit readable assembly listing
  --version/--help

fat [options] prog.fc [program args...]
  --trace        trace instructions
  --max-steps N  instruction budget
  --dump         dump the loaded image
  --version/--help
```

## Layout

```
src/             Erlang modules (compiler + runtime share one app)
include/         shared record definitions (bytecode image format)
priv/include/    bundled C standard headers
test/            end-to-end tests
doc/design.md    full design document
```

## Implemented status

Stages M0–M8 are implemented and covered by `test/run.sh` (each case is built
at both `-O0` and `-O1`):

- **Preprocessor**: line splicing, comment stripping, `#include` (quoted/angled,
  user + bundled headers), object- and function-like `#define`, `#`/`##`,
  `__VA_ARGS__`, `#if/#ifdef/#ifndef/#elif/#else/#endif`, `#undef`, `#pragma once`.
- **Language**: `void _Bool char short int long float double`, signed/unsigned,
  pointers, arrays, function pointers, `struct`/`union`/`enum`/`typedef`,
  qualifiers; full operator set, `if/while/do/for/switch/goto/break/continue`.
- **Libc**: `printf` family, string/memory functions, `malloc/calloc/realloc/free`,
  `atoi/strtol`, `qsort/bsearch` (re-entrant callbacks), ctype and `math`.
- **Backend**: stack bytecode, constant folding / peephole `-O1`, bytecode
  **verifier**, `.fc` linked image and `.fo` relocatable objects, separate
  linking (`fatcc -c` + `fatcc a.fo b.fo -o prog.fc`).
- **Runtime**: `fat` CLI, paged-v0 sparse memory, `--trace`, `--max-steps`,
  `--heap-size`, `--no-verify`.

Known limitations (see `doc/design.md` §11): bit-fields are parsed but not laid
out bit-exactly; structs are not passed/returned by value or assigned wholesale;
user-defined `va_list`/`va_arg` is not implemented (variadic *calls* and libc
`printf` work); `-g` debug info is accepted but not yet emitted; `.fc` uses a
CRC-checked term envelope rather than the chunked format.
