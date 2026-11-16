#!/usr/bin/env bash
# 用同一份生产源文件换成后台自检入口；SPM 负责模块和链接，套件清单只在 UI/main.swift。
set -euo pipefail
cd "$(dirname "$0")/.."
export SKYSHEET_UI_CHECKS=1
exec swift run --jobs 2 --arch arm64 --scratch-path .build/ui-checks SkySheet "$@"
