extension L10nStrings {
    static let alerts: [L10n.Entry] = [
        .init("alert.batch.title", "{0} 条提醒", "{0} {0|alert|alerts}"),
        .init("alert.quiet.title", "安静时段内有 {0} 条提醒", "{0} {0|alert|alerts} during quiet hours"),
        .init("alert.quiet.more", "…还有 {0} 条", "…and {0} more"),
        .init("alert.action.open", "打开面板", "Open Panel"),
        .init("alert.action.muteToday", "今天不再提醒", "Mute for Today"),
        .init("alert.recovered.title", "{0}{1}额度恢复了", "{0} {1} quota is back"),
        .init("alert.recovered.body", "现在剩余 {0}%，可以接着用了", "{0}% left — you're good to go"),
        .init("alert.lowTank.title", "{0} 余额不足", "{0} balance is low"),
        .init("alert.lowTank.body", "可用余额 {0}，已低于预警线 {1}", "Balance {0}, below your alert line of {1}"),
        .init("alert.keyLimit.title", "{0} Key 剩余额度不足", "{0} key limit is low"),
        .init("alert.keyLimit.body", "Key 剩余额度 {0}，已低于预警线 {1}", "Key limit left {0}, below your alert line of {1}"),
        .init("alert.quotaLow.title", "{0} 额度快用完了", "{0} quota is almost used up"),
        .init("alert.quotaLow.body", "剩余 {0}%，已低于预警线 {1}%", "{0}% left, below your alert line of {1}%"),
        .init("alert.spike.title", "{0} 用量异常增加", "{0} usage is spiking"),
        .init("alert.spike.body", "近 1 小时 {0}/时，是近 7 天平均的 {1} 倍。", "Last hour: {0}/h, {1}× the 7-day average."),
        .init("alert.spike.bodyDays", "近 1 小时 {0}/时，是近 {2} 天平均的 {1} 倍。", "Last hour: {0}/h, {1}× the {2}-day average."),
        .init("alert.hourly.title", "{0} 每小时花费超过 {1}", "{0} is spending over {1} per hour"),
        .init("alert.hourly.body", "每小时 {0}", "{0} per hour"),
        .init("alert.hourly.runway", "，预计可用时间：{0}", " · estimated time left: {0}"),
        .init("alert.runout.reset", "，下次重置：{0}", " · next reset: {0}"),
    ]
}
