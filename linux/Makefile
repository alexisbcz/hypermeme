# Hypermeme for Linux. Run from the repository root with `make -C linux <target>`.

run:
	-bin/hypermeme quit 2>/dev/null; sleep 0.5
	bin/hypermeme

test:
	python3 -m unittest discover -s tests -t . -v

install:
	./install.sh

uninstall:
	./install.sh --uninstall

.PHONY: run test install uninstall
