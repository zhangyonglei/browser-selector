.PHONY: build test app run benchmark project clean

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	open build/BrowserSelector.app

benchmark:
	./scripts/benchmark.sh 8

project:
	xcodegen generate

clean:
	rm -rf .build build
