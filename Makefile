# fatcc / fat -- C compiler and bytecode runtime in Erlang
#
# Targets:
#   make            compile all Erlang modules into ebin/
#   make test       run the end-to-end test suite
#   make clean      remove build artifacts
#
# Written to work with both GNU make and BSD make (the shell does the globbing).

ERLC ?= erlc

.PHONY: all test clean

all:
	@mkdir -p ebin
	@for f in src/*.erl; do \
	  echo "ERLC $$f"; \
	  $(ERLC) -I include -o ebin "$$f" || exit 1; \
	done
	@chmod +x bin/fatcc bin/fat

test: all
	./test/run.sh

clean:
	rm -rf ebin _build
	rm -f erl_crash.dump
