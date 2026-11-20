.PHONY: generate check-generate lint format test-ios test-ipad test-tvos test-mac test-admin test-admin-ipad test-admin-mac build-all screenshots check-store
generate: ; xcodegen generate --quiet
# Fails when make generate changes or adds any file, i.e. project.yml is not the full source of each Info.plist.
check-generate: generate
	git diff --exit-code
	test -z "$$(git status --porcelain)" || { git status --porcelain; exit 1; }
lint: ; scripts/ci.sh lint
format: ; xcrun swift-format format -i -r Apps Packages UITests
test-ios: generate ; scripts/ci.sh ios
test-ipad: generate ; scripts/ci.sh ipad
test-tvos: generate ; scripts/ci.sh tvos
test-mac: generate ; scripts/ci.sh mac
test-admin: generate ; scripts/ci.sh admin
test-admin-ipad: generate ; scripts/ci.sh admin-ipad
test-admin-mac: generate ; scripts/ci.sh admin-mac
build-all: generate ; scripts/ci.sh studio
screenshots: generate ; scripts/screenshots.sh $(or $(APP),all)
check-store: ; python3 scripts/check-store-metadata.py && scripts/test-release-version.sh
