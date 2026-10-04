#!/bin/bash
set -euo pipefail
SOURCE_VALIDATION="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cineva-source-selection"
mkdir -p "$SOURCE_VALIDATION"
python3 - "$SOURCE_VALIDATION/SourceSelection.swift" <<'PY'
from pathlib import Path
import sys
source = Path("Gallery115/Services/Cloud115Provider.swift").read_text(encoding="utf-8")
actual = source.split("// BEGIN PLAYBACK SOURCE SELECTION", 1)[1].split("// END PLAYBACK SOURCE SELECTION", 1)[0]
Path(sys.argv[1]).write_text("import Foundation\n" + actual, encoding="utf-8")
PY
swiftc Gallery115/Models/CloudItem.swift Gallery115/Models/VideoSource.swift \
  Gallery115/Services/CloudProvider.swift "$SOURCE_VALIDATION/SourceSelection.swift" \
  Tests/PlayerTransport/SourceSelectionChecks.swift -o "$SOURCE_VALIDATION/source-checks"
"$SOURCE_VALIDATION/source-checks"
