.PHONY: build test app run benchmark project icon clean

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

icon:
	python3 scripts/make-icon.py

clean:
	rm -rf .build build
