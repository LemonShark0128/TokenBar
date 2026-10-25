import SwiftUI

/// 界面文字（SwiftUI Text）：取当前语言的文案，并且和原来的 Text("字面量") 走同一条排版路径。
/// Text(String) 是逐字排版，中文标点附近的字距和 Text("字面量")（本地化路径）差一点点，预览对比会不一致；
/// 这里用 Text("\(…)")：文案作为参数放进本地化路径，里面的 % 不会被当成格式符
func LT(_ key: String, _ args: Any...) -> Text { Text("\(L10n.text(key, args))") }
