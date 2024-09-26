.PHONY: publish
publish: release ## alias for `make release`

.PHONY: release
release: cronjob-scripts/.python-deps-updated.timestamp ## Publish a new release
	(cd cargo-quickinstall/ && cargo release patch --execute --no-push)
	git push origin HEAD:release --tags
	$(MAKE) recheck

cronjob-scripts/requirements.txt: cronjob-scripts/pyproject.toml ## Compile the python dependencies from pyproject.toml into requirements.txt
	(cd cronjob-scripts && uv pip compile pyproject.toml --python-version=3.8 --output-file requirements.txt)

# install python dependencies and then record that we've done so so we don't do it again
# WARNING: this will mess with whatever python venv you happen to be in.
# this is run on the github actions runner so we can't use uv
cronjob-scripts/.python-deps-updated.timestamp: cronjob-scripts/requirements.txt
	python --version
	# FIXME: I don't think we really need both of these, but it's kind-of nice to use requirements.txt as the Makefile dependency for this rule.
	# Potentially we could just use the pyproject.toml file as the dependency and then run `pip install .` in the cronjob-scripts directory?
	# It feels like I've still not caught up with  what the best practices are for python packaging of devtool scripts + libs.
	pip install -r cronjob-scripts/requirements.txt
	python -m pip install --editable cronjob-scripts/
	touch cronjob-scripts/.python-deps-updated.timestamp

.PHONY: windows
windows: cronjob-scripts/.python-deps-updated.timestamp ## trigger a windows build
	RECHECK=1 TARGET=x86_64-pc-windows-msvc python cronjob-scripts/bin/trigger-package-build.py

.PHONY: mac
mac: cronjob-scripts/.python-deps-updated.timestamp ## trigger a mac build
	RECHECK=1 TARGET=x86_64-apple-darwin python cronjob-scripts/bin/trigger-package-build.py

.PHONY: m1
m1: cronjob-scripts/.python-deps-updated.timestamp ## trigger a mac m1 build
	RECHECK=1 TARGET=aarch64-apple-darwin python cronjob-scripts/bin/trigger-package-build.py

.PHONY: linux
linux: cronjob-scripts/.python-deps-updated.timestamp ## trigger a linux build
	RECHECK=1 TARGET=x86_64-unknown-linux-gnu python cronjob-scripts/bin/trigger-package-build.py

.PHONY: linux-musl
linux-musl: cronjob-scripts/.python-deps-updated.timestamp ## trigger a musl libc-based linux build
	RECHECK=1 TARGET=x86_64-unknown-linux-musl python cronjob-scripts/bin/trigger-package-build.py

.PHONY: recheck
recheck: cronjob-scripts/.python-deps-updated.timestamp ## build ourself and some random packages on all arches
	RECHECK=1 TARGET=all python cronjob-scripts/bin/trigger-package-build.py

.PHONY: trigger-all
trigger-all: cronjob-scripts/.python-deps-updated.timestamp ## build some random packages on all arches
	TARGET=all python cronjob-scripts/bin/trigger-package-build.py

.PHONY: fmt
fmt: ## run rustfmt and ruff format
	cargo fmt
	ruff format cronjob-scripts

.PHONY: test-cronjob-scripts
test-cronjob-scripts: cronjob-scripts/.python-deps-updated.timestamp ## run the tests for the python cronjob-scripts
	python -m ruff format --check cronjob-scripts
	python -m ruff check cronjob-scripts
	python -m unittest discover -s cronjob-scripts
	python cronjob-scripts/bin/trigger-package-build.py --help
	python cronjob-scripts/bin/stats.py
	python cronjob-scripts/bin/crates-io-popular-crates.py

.PHONY: help
help: ## Display this help screen
	@grep -E '^[a-z.A-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
