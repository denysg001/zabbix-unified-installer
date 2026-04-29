.PHONY: all lint check test

all: lint check test

lint:
	shellcheck -S warning AUTOMACAO-ZBX-UNIFIED.sh
	shfmt -d -i 4 AUTOMACAO-ZBX-UNIFIED.sh

check:
	bash -n AUTOMACAO-ZBX-UNIFIED.sh

test:
	bats tests/
