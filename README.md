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
