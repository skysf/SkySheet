#!/usr/bin/env bash
# 用同一份生产源文件换成后台自检入口；SPM 负责模块和链接，套件清单只在 UI/main.swift。
set -euo pipefail
cd "$(dirname "$0")/.."
export SKYSHEET_UI_CHECKS=1
# 两套构建串行、各限四个任务，避免共享机器在首次编译时耗尽内存。
swift build -j 4 --arch arm64 --scratch-path .build/ui-checks --product SkySheet
exec swift run --skip-build --arch arm64 --scratch-path .build/ui-checks SkySheet "$@"
