app := ".build/Fennec.app"

default: run

build:
    swift build -c release

# SwiftPM with only the Command Line Tools sometimes fails to load the Swift Testing macro plugin, so load it explicitly.
testing_plugin := "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

test:
    swift test -Xswiftc -load-plugin-library -Xswiftc {{testing_plugin}}

bundle version="": build
    rm -rf {{app}}
    mkdir -p {{app}}/Contents/MacOS {{app}}/Contents/Resources
    cp .build/release/Fennec {{app}}/Contents/MacOS/Fennec
    cp Resources/Info.plist {{app}}/Contents/Info.plist
    if [ -n "{{version}}" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString {{version}}" -c "Set :CFBundleVersion {{version}}" {{app}}/Contents/Info.plist; fi
    codesign --force --sign - {{app}}

# ditto keeps the bundle's signature intact, unlike zip.
package version: (bundle version)
    ditto -c -k --keepParent {{app}} .build/Fennec-{{version}}.zip

run: bundle
    open {{app}}

# Opens a folder with `count` files three times and prints load and paint timings.
bench count="50000": bundle
    #!/usr/bin/env bash
    set -euo pipefail
    dir="$(mktemp -d "${TMPDIR:-/tmp}/fennec-bench.XXXXXX")"
    trap 'rm -rf "$dir"' EXIT
    (cd "$dir" && seq -f "file-%06g.txt" 1 {{count}} | xargs touch)
    # Fixed view settings (argument-domain defaults) so results don't depend on how the app was last left.
    for i in 1 2 3; do
        FENNEC_BENCH=1 {{app}}/Contents/MacOS/Fennec "$dir" -viewMode list -previewVisible NO
    done
