.PHONY: publish
publish: release ## alias for `make release`

.PHONY: release
release: cronjob_scripts/.python-deps-updated.timestamp ## Publish a new release
	(cd cargo-quickinstall/ && cargo release patch --execute --no-push)
	git push origin HEAD:release --tags
	$(MAKE) recheck

cronjob_scripts/requirements.txt: cronjob_scripts/pyproject.toml ## Compile the python dependencies from pyproject.toml into requirements.txt
	(cd cronjob_scripts && uv pip compile pyproject.toml --python-version=3.8 --output-file requirements.txt)

# install python dependencies and then record that we've done so so we don't do it again
# WARNING: this will mess with whatever python venv you happen to be in.
# this is run on the github actions runner so we can't use uv
cronjob_scripts/.python-deps-updated.timestamp: cronjob_scripts/requirements.txt
	python --version
	pip install -r cronjob_scripts/requirements.txt
	touch cronjob_scripts/.python-deps-updated.timestamp

.PHONY: windows
windows: cronjob_scripts/.python-deps-updated.timestamp ## trigger a windows build
	RECHECK=1 TARGET_ARCH=x86_64-pc-windows-msvc python cronjob_scripts/trigger-package-build.py

.PHONY: mac
mac: cronjob_scripts/.python-deps-updated.timestamp ## trigger a mac build
	RECHECK=1 TARGET_ARCH=x86_64-apple-darwin python cronjob_scripts/trigger-package-build.py

.PHONY: m1
m1: cronjob_scripts/.python-deps-updated.timestamp ## trigger a mac m1 build
	RECHECK=1 TARGET_ARCH=aarch64-apple-darwin python cronjob_scripts/trigger-package-build.py

.PHONY: linux
linux: cronjob_scripts/.python-deps-updated.timestamp ## trigger a linux build
	RECHECK=1 TARGET_ARCH=x86_64-unknown-linux-gnu python cronjob_scripts/trigger-package-build.py

.PHONY: linux-musl
linux-musl: cronjob_scripts/.python-deps-updated.timestamp ## trigger a musl libc-based linux build
	RECHECK=1 TARGET_ARCH=x86_64-unknown-linux-musl python cronjob_scripts/trigger-package-build.py

.PHONY: recheck
recheck: cronjob_scripts/.python-deps-updated.timestamp ## build ourself and some random packages on all arches
	RECHECK=1 TARGET_ARCH=all python cronjob_scripts/trigger-package-build.py

.PHONY: trigger-all
trigger-all: cronjob_scripts/.python-deps-updated.timestamp ## build some random packages on all arches
	TARGET_ARCH=all python cronjob_scripts/trigger-package-build.py

.PHONY: test-cronjob-scripts
test-cronjob-scripts: cronjob_scripts/.python-deps-updated.timestamp ## run the tests for the python cronjob_scripts
	python -m unittest discover -s cronjob_scripts
	python cronjob_scripts/trigger-package-build.py --help

.PHONY: help
help: ## Display this help screen
	@grep -E '^[a-z.A-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
