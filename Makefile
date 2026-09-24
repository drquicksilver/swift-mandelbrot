# Builds, tests and checks the app from the command line; README.md lists the
# targets people run.  There is no CI: `make test` and `make apptests` are the
# gate before a commit.  Every build goes to /tmp, never into the source tree.

BUILD_DIR ?= /tmp/mandelbrot-development
APP = $(BUILD_DIR)/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot

.PHONY: build test unit cli golden smooth tiles product deep bla ios ios-device format format-check strings strings-check apptests docs docs-check

build:
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -configuration Release -destination 'platform=macOS' -derivedDataPath $(BUILD_DIR) CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build

# The Core package's unit tests, then end-to-end tests that drive the Release
# app headless: its command line, the golden images and the tile integration.
test: unit cli golden smooth tiles product deep bla
unit:
	swift test
cli: build
	MANDELBROT_TEST_METAL=1 python3 tests/cli/test_headless.py $(APP)
golden: build
	python3 tests/cli/test_golden.py $(APP)
smooth: build
	python3 tests/cli/test_smooth.py $(APP)
tiles: build
	$(APP) --test-tiles
product: build
	python3 tests/cli/test_product_golden.py $(APP)
deep: build
	python3 tests/cli/test_deep.py $(APP)
	python3 tests/cli/test_minibrot.py $(APP)
bla: build
	python3 tests/cli/test_bla.py $(APP)

ios:
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath $(BUILD_DIR)-ios CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build
	python3 tests/cli/test_app_bundle.py $(BUILD_DIR)-ios/Build/Products/Release-iphonesimulator/Mandelbrot.app/Info.plist
ios-device:
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -configuration Release -destination 'generic/platform=iOS' -derivedDataPath $(BUILD_DIR)-device CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build
	python3 tests/cli/test_app_bundle.py $(BUILD_DIR)-device/Build/Products/Release-iphoneos/Mandelbrot.app/Info.plist

# xcodebuild extracts strings but, unlike the IDE, never writes them back.
# The tool writes the catalogue exactly as Xcode would, so the two agree.
STRINGS = $(BUILD_DIR)/Build/Intermediates.noindex/Mandelbrot.build/Release $(BUILD_DIR)-ios/Build/Intermediates.noindex/Mandelbrot.build/Release-iphonesimulator
strings: build ios
	swift tools/update_strings.swift $(STRINGS)
strings-check: build ios
	swift tools/update_strings.swift --check $(STRINGS)

# The app's own tests (tests/app and tests/ui), on the Mac and on an iPad
# simulator: the iPad is where hardware-keyboard commands differ, and the Mac
# cannot show it.
# The first available iPad simulator, by id.  simctl answers at once, where
# xcodebuild -showdestinations can come back empty while the simulator
# service wakes; naming a model picks the newest runtime, which may not fit.
IPAD ?= $(shell xcrun simctl list devices available | grep -m1 -E '^ +iPad' | grep -oE '[0-9A-F-]{36}')
apptests:
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -destination 'platform=macOS' -derivedDataPath $(BUILD_DIR)-apptests CODE_SIGNING_ALLOWED=NO test -only-testing:MandelbrotTests
	# One bundle at a time, on one simulator: run together, xcodebuild puts the
	# unit and UI bundles on two clones at once, and every test ran about five
	# times slower, past the deadlines of the render tests.
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -destination 'platform=iOS Simulator,id=$(IPAD)' -derivedDataPath $(BUILD_DIR)-apptests-ios -parallel-testing-enabled NO build-for-testing
	# The UI test goes first: straight after the unit tests, SpringBoard
	# refused to launch its runner ("Busy", "failed preflight checks") every
	# time.  That failure, and only that, is also retried once; a test that
	# fails is never retried.
	@log=$$(mktemp); ui="xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -destination platform=iOS\ Simulator,id=$(IPAD) -derivedDataPath $(BUILD_DIR)-apptests-ios -parallel-testing-enabled NO test-without-building -only-testing:MandelbrotUITests/KeyboardUITests"; \
	if ! eval $$ui > $$log 2>&1; then \
	  if grep -q "failed preflight checks" $$log; then echo "The simulator was busy launching the UI runner; retrying once"; eval $$ui; \
	  else cat $$log; exit 1; fi; \
	fi
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -destination 'platform=iOS Simulator,id=$(IPAD)' -derivedDataPath $(BUILD_DIR)-apptests-ios -parallel-testing-enabled NO test-without-building -only-testing:MandelbrotTests

format:
	rg --files -g '*.swift' -g '!Mandelbrot/Core/Vendor/**' -0 | xargs -0 xcrun swift-format format --configuration .swift-format --in-place
format-check:
	rg --files -g '*.swift' -g '!Mandelbrot/Core/Vendor/**' -0 | xargs -0 xcrun swift-format lint --configuration .swift-format --strict

# Aligns the documents' tables for monospace reading and checks their links.
DOCS = README.md docs/*.md tests/fixtures/README.md benchmarks/README.md benchmarks/reference-library/README.md
docs:
	python3 tools/check_docs.py --fix $(DOCS)
docs-check:
	python3 tools/check_docs.py $(DOCS)
