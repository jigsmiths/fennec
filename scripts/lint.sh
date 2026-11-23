#!/usr/bin/env bash
# Usage: scripts/lint.sh [repo-root]
# Allow a line with: // lint-allow: <reason>, expires YYYY-MM-DD, approved-by <name>
set -uo pipefail

root="${1:-.}"
today="$(date +%F)"
status=0

check() {
    local pattern="$1" fix="$2"
    while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        local line="${hit#*:*:}"
        if [[ "$line" =~ //\ lint-allow:\ .+,\ expires\ ([0-9]{4}-[0-9]{2}-[0-9]{2}),\ approved-by\ [^[:space:]]+ ]]; then
            if [[ ! "${BASH_REMATCH[1]}" < "$today" ]]; then continue; fi
            echo "${hit%%:*:*}: lint-allow expired on ${BASH_REMATCH[1]}"
        fi
        echo "${hit%"$line"} $fix"
        status=1
    done < <(cd "$root" && grep -rnE "$pattern" Sources Tests --include='*.swift')
}

check '@unchecked Sendable' \
    'Make the type Sendable by guarding state with Mutex or Atomic (Synchronization), like CancelFlag or TrashLedger.'
check 'nonisolated\(unsafe\)' \
    'Wrap the value in a Mutex (Synchronization), like FileFormatting'"'"'s formatters.'
check 'Unmanaged\.passUnretained\(' \
    'Pass a retained receiver: FSEventStreamContext.retaining(_:) for FSEvents, or Unmanaged.passRetained with a matching release.'
check '// MARK:' \
    'Remove the banner. Split the file or extract a type if it needs sections.'

exit $status
