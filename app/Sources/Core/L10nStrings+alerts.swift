extension L10nStrings {
    static let alerts: [L10n.Entry] = [
        .init("alert.lowTank.title", "{0} 余额不足", "{0} balance is low"),
        .init("alert.lowTank.body", "可用余额 {0}，已低于预警线 {1}", "Balance {0}, below your alert line of {1}"),
        .init("alert.quotaLow.title", "{0} 额度快用完了", "{0} quota is almost used up"),
        .init("alert.quotaLow.body", "剩余 {0}%，已低于预警线 {1}%", "{0}% left, below your alert line of {1}%"),
        .init("alert.spike.title", "{0} 用量异常增加", "{0} usage is spiking"),
        .init("alert.spike.body", "近 1 小时 ¥{0}/时，是近 7 天平均的 {1} 倍。", "Last hour: ¥{0}/h, {1}× the 7-day average."),
        .init("alert.hourly.title", "{0} 每小时花费超过 {1}", "{0} is spending over {1} per hour"),
        .init("alert.hourly.body", "每小时 {0}", "{0} per hour"),
        .init("alert.hourly.runway", "，预计可用时间：{0}", " · estimated time left: {0}"),
        .init("alert.runout.title", "{0} 重置前会用完", "{0} will run out before reset"),
        .init("alert.runout.body", "预计可用时间：{0}", "Estimated time left: {0}"),
        .init("alert.runout.reset", "，下次重置：{0}", " · next reset: {0}"),
    ]
}
