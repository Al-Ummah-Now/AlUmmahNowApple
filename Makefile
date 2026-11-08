.PHONY: generate lint format test-ios test-ipad test-tvos test-mac build-all
generate: ; xcodegen generate --quiet
lint: ; scripts/ci.sh lint
format: ; xcrun swift-format format -i -r Apps Packages UITests
test-ios: generate ; scripts/ci.sh ios
test-ipad: generate ; scripts/ci.sh ipad
test-tvos: generate ; scripts/ci.sh tvos
test-mac: generate ; scripts/ci.sh mac
build-all: generate ; scripts/ci.sh studio
