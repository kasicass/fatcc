# fatcc / fat -- C compiler and bytecode runtime in Erlang
#
# Targets:
#   make            compile all Erlang modules into ebin/
#   make test       run the end-to-end test suite
#   make clean      remove build artifacts

ERLC ?= erlc
ERL  ?= erl
SRC  := $(wildcard src/*.erl)
BEAM := $(patsubst src/%.erl,ebin/%.beam,$(SRC))

.PHONY: all test clean

all: $(BEAM) bin/fatcc bin/fat

ebin:
	mkdir -p ebin

ebin/%.beam: src/%.erl include/fat_image.hrl | ebin
	$(ERLC) -I include -o ebin $<

bin/fatcc bin/fat: bin/%
	chmod +x $@

test: all
	./test/run.sh

clean:
	rm -rf ebin _build
	rm -f erl_crash.dump
