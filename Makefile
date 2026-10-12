# Bealach — local development entry points.
#
# CI is local-only by design (no GitHub Actions, no paid hosted runners).
# Everything goes through ci/check.sh; see ci/README.md.

.PHONY: help ci ci-linux links local-ci-policy tools-go harvest-rust clean

help:
	@sed -n '3,8p' Makefile

## Run every check natively (macOS or Linux).
ci:
	@ci/check.sh

## Run the same checks in a Linux container (OrbStack or Docker).
ci-linux:
	@ci/linux.sh

## Run a single check.
links:
	@ci/check.sh links

local-ci-policy:
	@ci/check.sh local-ci-policy

tools-go:
	@ci/check.sh tools-go

harvest-rust:
	@ci/check.sh harvest-rust

clean:
	rm -rf build/ci harvest/firmware/tools/enginegen/target
