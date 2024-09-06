.PHONY: publish
publish: release ## alias for `make release`

.PHONY: release
release: scripts/.python-deps-updated.timestamp ## Publish a new release
	(cd cargo-quickinstall/ && cargo release patch --execute --no-push)
	git push origin HEAD:release --tags
	make recheck

scripts/requirements.txt: scripts/pyproject.toml
	(cd scripts && uv pip compile pyproject.toml --python-version=3.8 --output-file requirements.txt)

# install python dependencies and then record that we've done so so we don't do it again
# WARNING: this will mess with whatever python venv you happen to be in.
# this is run on the github actions runner so we can't use uv
scripts/.python-deps-updated.timestamp: scripts/requirements.txt
	python --version
	pip install -r scripts/requirements.txt
	touch scripts/.python-deps-updated.timestamp

.PHONY: windows
windows: scripts/.python-deps-updated.timestamp ## trigger a windows build
	RECHECK=1 TARGET_ARCH=x86_64-pc-windows-msvc python scripts/trigger-package-build.py

.PHONY: mac
mac: scripts/.python-deps-updated.timestamp ## trigger a mac build
	RECHECK=1 TARGET_ARCH=x86_64-apple-darwin python scripts/trigger-package-build.py

.PHONY: m1
m1: scripts/.python-deps-updated.timestamp ## trigger a mac m1 build
	RECHECK=1 TARGET_ARCH=aarch64-apple-darwin python scripts/trigger-package-build.py

.PHONY: linux
linux: scripts/.python-deps-updated.timestamp ## trigger a linux build
	RECHECK=1 TARGET_ARCH=x86_64-unknown-linux-gnu python scripts/trigger-package-build.py

.PHONY: linux-musl
linux-musl: scripts/.python-deps-updated.timestamp ## trigger a musl libc-based linux build
	RECHECK=1 TARGET_ARCH=x86_64-unknown-linux-musl python scripts/trigger-package-build.py

.PHONY: exclude
exclude: scripts/.python-deps-updated.timestamp ## recompute excludes, but don't push anywhere (see /tmp/cargo-quickinstall-* for repos)
	REEXCLUDE=1 python scripts/trigger-package-build.py

.PHONY: recheck
recheck: scripts/.python-deps-updated.timestamp ## recompute excludes and start from the top
	RECHECK=1 python scripts/trigger-package-build.py

.PHONY: help
help: ## Display this help screen
	@grep -E '^[a-z.A-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
