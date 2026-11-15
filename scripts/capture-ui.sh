#!/usr/bin/env bash
# 固定外观、选区和缩放，避免机器的当前深色设置或滚动位置污染前后像素比较；只写全新目录。
set -euo pipefail
cd "$(dirname "$0")/.."
APP=$1
INPUTS=$2
OUTPUT=$3
mkdir "${OUTPUT}"
capture() {
  "${APP}" --snapshot-input "$1" --snapshot-output "${OUTPUT}/$2.png" --select "$3" \
    --appearance aqua "${@:4}" > "${OUTPUT}/$2.log" 2>&1
}
capture Fixtures/loan.xlsx loan-A1 A1
capture Fixtures/loan.xlsx loan-K60 K60
capture Fixtures/loan.xlsx loan-AB150 AB150
capture Fixtures/loan.xlsx loan-range A1:D8 --zoom 1.37
for kind in data formulas styles; do capture "${INPUTS}/${kind}.xlsx" "${kind}-K60" K60; done
capture "${INPUTS}/merge.xlsx" merge-top B2
capture "${INPUTS}/merge.xlsx" merge-scroll E3
capture "${INPUTS}/center.xlsx" center A1
capture "${INPUTS}/extent.xlsx" extent-AA1 AA1
capture "${INPUTS}/extent.xlsx" extent-A101 A101
capture "${INPUTS}/extent.xlsx" extent-AZ201 AZ201
