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
# 测试往系统临时目录写 tb-* / tokenbar-test* 目录且不清理（Foundation 在这台机器上不认 TMPDIR）；
# 跑完只删「比本次标记文件新」的这些目录，不碰以前留下的和别的程序的
SYS_TMP="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
MARK="$(mktemp "${SYS_TMP}tokenbar-tests-mark.XXXXXX")"
cleanup_tests_tmp() {
  find "$SYS_TMP" -maxdepth 1 -type d \( -name 'tb-*' -o -name 'tokenbar-test*' \) -newer "$MARK" -exec rm -rf {} + 2>/dev/null || true
  rm -f "$MARK"
}
trap cleanup_tests_tmp EXIT
build/TokenBarTests
