#!/bin/bash
set -euo pipefail
SOURCE_VALIDATION="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cineva-source-selection"
mkdir -p "$SOURCE_VALIDATION"
python3 - "$SOURCE_VALIDATION" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1])
source = Path("Gallery115/Services/Cloud115Provider.swift").read_text(encoding="utf-8")
actual = source.split("// BEGIN PLAYBACK SOURCE SELECTION", 1)[1].split("// END PLAYBACK SOURCE SELECTION", 1)[0]
output.joinpath("SourceSelection.swift").write_text("import Foundation\n" + actual, encoding="utf-8")
# macOS Foundation exposes CGRect storage without CoreGraphics conveniences.
# Keep the actual model body intact and supply the iOS module's geometry import.
model = Path("Gallery115/Models/CloudItem.swift").read_text(encoding="utf-8")
output.joinpath("CloudItem.swift").write_text("import CoreGraphics\n" + model, encoding="utf-8")
PY
swiftc "$SOURCE_VALIDATION/CloudItem.swift" Gallery115/Models/VideoSource.swift \
  Gallery115/Services/CloudProvider.swift "$SOURCE_VALIDATION/SourceSelection.swift" \
  Tests/PlayerTransport/SourceSelectionChecks.swift -o "$SOURCE_VALIDATION/source-checks"
"$SOURCE_VALIDATION/source-checks"
