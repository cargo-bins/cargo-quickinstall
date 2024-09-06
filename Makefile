.PHONY: publish
publish: release ## alias for `make release`

.PHONY: release
release: ## Publish a new release
	(cd cargo-quickinstall/ && cargo release patch --execute --no-push)
	git push origin HEAD:release --tags
	make recheck

.PHONY: windows
windows: ## trigger a windows build
	RECHECK=1 TARGET_ARCH=x86_64-pc-windows-msvc python scripts/trigger-package-build.py

.PHONY: mac
mac: ## trigger a mac build
	RECHECK=1 TARGET_ARCH=x86_64-apple-darwin python scripts/trigger-package-build.py

.PHONY: m1
m1: ## trigger a mac m1 build
	RECHECK=1 TARGET_ARCH=aarch64-apple-darwin python scripts/trigger-package-build.py

.PHONY: linux
linux: ## trigger a linux build
	RECHECK=1 TARGET_ARCH=x86_64-unknown-linux-gnu python scripts/trigger-package-build.py

.PHONY: linux-musl
linux-musl: ## trigger a musl libc-based linux build
	RECHECK=1 TARGET_ARCH=x86_64-unknown-linux-musl python scripts/trigger-package-build.py

.PHONY: exclude
exclude: ## recompute excludes, but don't push anywhere (see /tmp/cargo-quickinstall-* for repos)
	REEXCLUDE=1 python scripts/trigger-package-build.py

.PHONY: recheck
recheck: ## recompute excludes and start from the top
	RECHECK=1 python scripts/trigger-package-build.py

.PHONY: help
help: ## Display this help screen
	@grep -E '^[a-z.A-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
