BUILD_DIR ?= /tmp/mandelbrot-development
APP = $(BUILD_DIR)/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot

.PHONY: build test unit cli golden smooth tiles product ios ios-device format format-check
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
tiles: build
	$(APP) --test-tiles
product: build
	python3 tests/test_product_golden.py $(APP)
test: unit cli golden smooth tiles product
ios:
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath $(BUILD_DIR)-ios CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build

	python3 tests/test_app_bundle.py $(BUILD_DIR)-ios/Build/Products/Release-iphonesimulator/Mandelbrot.app/Info.plist

format:
	rg --files -g '*.swift' -0 | xargs -0 xcrun swift-format format --configuration .swift-format --in-place
format-check:
	rg --files -g '*.swift' -0 | xargs -0 xcrun swift-format lint --configuration .swift-format --strict

ios-device:
	xcodebuild -quiet -project Mandelbrot.xcodeproj -scheme Mandelbrot -configuration Release -destination 'generic/platform=iOS' -derivedDataPath $(BUILD_DIR)-device CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build
	python3 tests/test_app_bundle.py $(BUILD_DIR)-device/Build/Products/Release-iphoneos/Mandelbrot.app/Info.plist
