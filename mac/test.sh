#!/bin/sh
# mac 外壳的测试：只测不碰系统接口的逻辑（现在是跟随窗口的挑选，FollowPick.swift）
set -eu
cd "$(dirname "$0")"
mkdir -p build/test
# 带顶层代码的文件要叫 main.swift 才能和别的文件一起编译
cp tests/FollowPickTests.swift build/test/main.swift
swiftc -swift-version 5 -o build/test/follow-pick build/test/main.swift FollowPick.swift
./build/test/follow-pick
