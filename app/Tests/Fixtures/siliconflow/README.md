# 硅基流动样本（合成 + Task 10 真实录制）

**这些文件是手写的合成样本**，字段依据仓库根目录 `providers.py`（`_sf_wallet`、`_sf_agg`、`_sf_items`、`_sf_item_row`、`sf_subject_id`）推出，金额、id、名称全部虚构。**必须在 Task 10 用真实录制再核对一次**（尤其：钱包 `financialInfo` 的其他字段、汇总接口的其他键、`pagination` 字段名、`objectName` 的真实格式）。

| 文件 | 端点 / 用途 | 含义 |
|---|---|---|
| `wallet.json` | `GET walletd.../api/v1/subject/profile` | `balance: "27070000000000"` ÷ 10¹² = ¥27.07 |
| `wallet_no_financialinfo.json` | 同上 | 结构不符，期望 `.schemaChanged` |
| `biz_code_40001.json` | 任一接口，HTTP 200 | `code: 40001`，期望 `.auth`（401/403 状态码由测试直接构造） |
| `aggregate_today.json` | `bill/aggregate_amount`（今日） | `netAmount` = 1.37 |
| `aggregate_month.json` | `bill/aggregate_amount`（本月） | `netAmount` = 4.87 |
| `items_single.json` | `bill/items`，`pages: 1` | 4 行，期望只请求 1 页 |
| `items_page1.json` / `items_page2.json` | `bill/items?current=1/2`，`pages: 2` | 同样 4 行拆成两页（各 2 行）；这两页声明 `pageSize: 2`（测试请求用 `pageSize=2`），与 providers.py「行数 < pageSize 即停」一致 |
| `console_bills.html` | 控制台页面 | 含 `window.SF_SUBJECT_ID = 'sid-test-0001';` |
| `console_bills_no_subject.html` | 控制台页面 | 无 subject id，期望 `.auth("硅基流动登录已失效")` |

明细 4 行（时间戳取 UTC 04:00–10:00，在 UTC 与 UTC+8 下落在同一天）：10-15 `test-model-a`（objectName 为多语言 JSON 串，取中文，`.` 前为模型名）0.80/80000、10-15 `test-model-b`（普通字符串 `test-model-b.输出`）0.57/57000、10-14 model-a 2.00/200000、10-10 model-b 1.50/150000。

期望：今日 ¥1.37（= 10-15 两行之和），本月 ¥4.87；byModel：model-a cost 2.80 / output 280000 / requests 2，model-b cost 2.07 / output 207000 / requests 2；trend7 有 10-10、10-14、10-15 三天。

注意：`providers.py` 在「本页行数 < pageSize」或到达最后一页时停止；`items_single.json` 的 pageSize 为 100、`pages: 1`，分页两页样本的 pageSize 为 2，两种规则下结果一致。

## Task 10 真实录制（2026-10-15，App 调试命令 `recordsf`）

`recorded_*.json` 是真实响应，**已脱敏**：`uId`、`billingId` 换成假值；没有 cookie、subject id（录制只存响应正文，不存请求头、控制台 HTML）。金额是真实的。

与合成样本的差别（已据此修代码）：
- 顶层只有 `code` 和 `data`，没有 `message`。
- 明细 `pagination` 只有 `current / pageSize / total`，**没有 `pages`**：按 `total / pageSize` 向上取整（`items_nopages_page1/2.json` 测这个）。
- `objectName` 是普通字符串「模型.服务方式.计费项」，模型名自身可带点：`qwen/qwen3-asr-1.7b.online.input-audio-seconds`。
- 明细行另有 `billingId`、`tags`、`objectId`、`deductUsage`、`netUsage`、`grossAmount`、`createdAt`、`uId` 等字段；`objectUnit` 可能是「秒」等非 token 单位。
- 钱包 `financialInfo` 另有 `available`、`recharged`、`used`、`lineOfCredit` 等，全是 10^-12 元的整数字符串。
- 汇总接口另有 `reduceAmount`、`deductUsage`、`redeemAmount`、`grossAmount`。

## 明细截断（评审 I-2，合成）

`items_many.json`：同 `items_nopages_page1.json` 的 2 行，但 `total: 1000`（`pageSize: 2` 时 500 页），用来测「到页数上限即停、标不完整」。
