.PHONY: generate open test build clean

generate:
	xcodegen generate

open: generate
	open MediaSqueeze.xcodeproj

test:
	swift test --package-path Packages/SqueezeCore

build: generate
	xcodebuild build \
		-project MediaSqueeze.xcodeproj \
		-scheme MediaSqueeze \
		-destination 'generic/platform=iOS Simulator' \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO

clean:
	rm -rf MediaSqueeze.xcodeproj build.log
