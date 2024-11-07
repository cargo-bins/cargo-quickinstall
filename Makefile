.PHONY: publish
publish: release ## alias for `make release`

.PHONY: release
release: cronjob_scripts/.python-deps-updated.timestamp ## Publish a new release
	(cd cargo-quickinstall/ && cargo release patch --execute --no-push)
	git push origin HEAD:release --tags
	$(MAKE) recheck

# This is a poor man's lockfile.
# This format is used because it is well supported by dependabot etc.
# but for now, we do not have access to `uv` in CI and don't automatically update requirements.txt
# as part of our make rules. I might revisit this decision later.
requirements.txt: pyproject.toml ## Compile the python dependencies from pyproject.toml into requirements.txt
	uv pip compile pyproject.toml --python-version=3.8 --output-file requirements.txt

.venv/bin/python:
	python -m venv .venv

# install python dependencies and then record that we've done so so we don't do it again
cronjob_scripts/.python-deps-updated.timestamp: pyproject.toml .venv/bin/python
	.venv/bin/python --version
	.venv/bin/python -m pip install --constraint requirements.txt --editable .
	touch cronjob_scripts/.python-deps-updated.timestamp

.PHONY: windows
windows: cronjob_scripts/.python-deps-updated.timestamp ## trigger a windows build
	RECHECK=1 TARGET_ARCH=x86_64-pc-windows-msvc .venv/bin/trigger-package-build

.PHONY: mac
mac: cronjob_scripts/.python-deps-updated.timestamp ## trigger a mac build
	RECHECK=1 TARGET_ARCH=x86_64-apple-darwin .venv/bin/trigger-package-build

.PHONY: m1
m1: cronjob_scripts/.python-deps-updated.timestamp ## trigger a mac m1 build
	RECHECK=1 TARGET_ARCH=aarch64-apple-darwin .venv/bin/trigger-package-build

.PHONY: linux
linux: cronjob_scripts/.python-deps-updated.timestamp ## trigger a linux build
	RECHECK=1 TARGET_ARCH=x86_64-unknown-linux-gnu .venv/bin/trigger-package-build

.PHONY: linux-musl
linux-musl: cronjob_scripts/.python-deps-updated.timestamp ## trigger a musl libc-based linux build
	RECHECK=1 TARGET_ARCH=x86_64-unknown-linux-musl .venv/bin/trigger-package-build

.PHONY: recheck
recheck: cronjob_scripts/.python-deps-updated.timestamp ## build ourself and some random packages on all arches
	RECHECK=1 TARGET_ARCH=all .venv/bin/trigger-package-build

.PHONY: trigger-all
trigger-all: cronjob_scripts/.python-deps-updated.timestamp ## build some random packages on all arches
	TARGET_ARCH=all .venv/bin/trigger-package-build

.PHONY: fmt
fmt: ## run rustfmt and ruff format
	cargo fmt
	.venv/bin/ruff format cronjob_scripts

.PHONY: test-cronjob-scripts
test-cronjob-scripts: cronjob_scripts/.python-deps-updated.timestamp ## run the tests for the python cronjob_scripts
	.venv/bin/ruff format --check cronjob_scripts
	.venv/bin/ruff check cronjob_scripts
	.venv/bin/python -m unittest discover -s cronjob_scripts
	.venv/bin/trigger-package-build --help
	.venv/bin/crates-io-popular-crates
	.venv/bin/stats

.PHONY: help
help: ## Display this help screen
	@grep -E '^[a-z.A-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
