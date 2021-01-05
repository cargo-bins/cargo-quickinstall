.PHONY: publish
publish: release ## alias for `make release`

.PHONY: release
release: ## Publish a new release
	(cd cargo-quickinstall/ && cargo release patch)

.PHONY: help
help: ## Display this help screen
	@grep -E '^[a-z.A-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
