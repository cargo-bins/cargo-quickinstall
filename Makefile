.PHONY: publish
publish: ## Publish a new release
	cargo bump
	cargo build
	git commit -am "build new version"
	(cd cargo-quickinstall/ && cargo publish)

.PHONY: help
help: ## Display this help screen
	@grep -E '^[a-z.A-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'
