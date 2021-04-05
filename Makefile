.PHONY: publish
publish: release ## alias for `make release`

.PHONY: release
release: ## Publish a new release
	(cd cargo-quickinstall/ && cargo release patch)
	RECHECK=1 ./trigger-package-build.sh

.PHONY: windows
windows: ## trigger a windows build
	RECHECK=1 TARGET=x86_64-pc-windows-msvc ./trigger-package-build.sh

.PHONY: mac
mac: ## trigger a mac build
	RECHECK=1 TARGET=x86_64-apple-darwin ./trigger-package-build.sh

.PHONY: linux
linux: ## trigger a linux build
	RECHECK=1 TARGET=x86_64-unknown-linux-gnu ./trigger-package-build.sh

.PHONY: help
help: ## Display this help screen
	@grep -E '^[a-z.A-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
