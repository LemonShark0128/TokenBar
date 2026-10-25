#!/bin/bash
# 编译 Core + Tests 成测试程序并运行（Core 若引用界面代码，这里会直接编译失败）
# 默认不跑写真实钥匙串的 CredentialStoreTests；要跑时：TOKENBAR_KEYCHAIN_TESTS=1 bash app/test.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./sdk.sh
mkdir -p build
/usr/bin/swiftc -O -swift-version 5 -strict-concurrency=complete -parse-as-library \
  -sdk "$SDK" \
  -target "$(uname -m)-apple-macosx14.0" -lsqlite3 \
  -o build/TokenBarTests Sources/Core/*.swift Tests/*.swift
build/TokenBarTests
