# 选 macOS SDK（build.sh / test.sh 共用，source 进来后用 $SDK）：
# 1. 环境变量 SDKROOT；2. 本机命令行工具里和编译器匹配的 26.5（这台机器上 27.0 SDK 比编译器新，编不过）；
# 3. xcrun 给的默认 SDK（装了完整 Xcode 的机器一般就是匹配的）
SDK="${SDKROOT:-}"
if [ -z "$SDK" ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
if [ -z "$SDK" ]; then SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
