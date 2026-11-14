.PHONY: generate lint format test-ios test-ipad test-tvos test-mac test-admin test-admin-ipad test-admin-mac build-all
generate: ; xcodegen generate --quiet
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
