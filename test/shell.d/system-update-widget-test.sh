#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const widget = fs.readFileSync(path.join(root, 'shell/plugins/bar/widgets/SystemUpdate.qml'), 'utf8')

assert(
  /onExited: function\(exitCode\) \{\s*if \(exitCode === 0\) root\.updateAvailable = true\s*else if \(exitCode === 1\) root\.updateAvailable = false\s*\}/.test(widget),
  'the update widget changes state only for definitive available and current results'
)

assert(
  !/root\.updateAvailable = exitCode === 0/.test(widget),
  'an update-detection error cannot clear a pending indicator'
)
JS
