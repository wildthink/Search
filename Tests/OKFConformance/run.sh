#!/bin/sh
# Whatever Search writes, OKFFormat reads the same, and the other way round.
# OKF_FORMAT_PATH=../path/to/OKFFormat ./run.sh to test an unpushed checkout.
set -eu
cd "$(dirname "$0")"
swift run -c release Conformance "$@"
