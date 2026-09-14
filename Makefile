BUILD_DIR ?= /tmp/mandelbrot-development
APP = $(BUILD_DIR)/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot

.PHONY: build test unit cli golden ios
build:
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -configuration Release -destination 'platform=macOS' -derivedDataPath $(BUILD_DIR) CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build
unit:
	swift test
cli: build
	MANDELBROT_TEST_METAL=1 python3 tests/test_headless.py $(APP)
golden: build
	python3 tests/test_golden.py $(APP)
smooth: build
	python3 tests/test_smooth.py $(APP)
test: unit cli golden smooth
ios:
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath $(BUILD_DIR)-ios CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build
