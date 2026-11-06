#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECONDS_TO_RUN="${1:-8}"

swift build -c release --package-path "$ROOT"
BIN_DIR="$(swift build -c release --package-path "$ROOT" --show-bin-path)"

echo "运行 ${SECONDS_TO_RUN}s 空闲基准（输出一行 benchmark 数据）…"
"$BIN_DIR/BrowserSelector" --benchmark "$SECONDS_TO_RUN"
