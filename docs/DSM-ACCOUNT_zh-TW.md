# 這個 plugin 需要的 DSM 帳號權限

**不要把 `admin` 帳號給這個 plugin。** 建一個專用帳號、把它不需要的東西全部關掉、
再限制它能從哪裡登入。這份文件說明怎麼做，也誠實說明 Synology 不讓你限制的那一部分。

以下內容於 2026-08-06 在一台 **DS918+（DSM 7.1.1-42962 Update 9）** 上以唯讀方式
實測取得。無法用這種方式確認的地方，文中會明說。

---

## 簡短版

```
建立本機使用者，例如  pve-storage
  群組          administrators（管理員）   <-- 必要，理由見下
  共用資料夾    全部設為「無法存取」
  應用程式      除 DSM 之外全部拒絕
  配額          不需要
  速度限制      不需要
  兩步驟驗證    可選（見下——plugin 能保存 device token）
然後在控制台：
  安全性 > 防火牆   DSM 連接埠只允許來自 PVE 節點的位址
  安全性 > 帳號     自動封鎖保持開啟（它保護的是你；plugin 寫成不會去踩它）
```

---

## 為什麼必須是管理員群組，以及那代表什麼、不代表什麼

SAN Manager 的 Web API——`SYNO.Core.ISCSI.LUN`、`SYNO.Core.ISCSI.Target`、
`SYNO.Core.ISCSI.Host`、`SYNO.Core.Storage.Volume`——屬於 DSM 核心，不屬於套件。
**DSM 沒有任何一個可以單獨授予的「管理 LUN」權限。** 沒有 SAN 操作員角色，
每位使用者的「應用程式權限」清單裡也沒有 SAN Manager。所以非管理員帳號沒有任何
有文件依據的方式能呼叫這些 API。

**這是 DSM 的限制，不是本 plugin 便宜行事。** 和相關專案面對的那些陣列相比——
那些可以建立範圍限定在儲存區的角色——這確實是一個退步，而你在決定 NAS 的網路
配置之前應該先知道這件事。

在管理員群組裡**不代表**也必須給的東西：

| 也要給嗎 | 不用，因為 |
|---|---|
| 共用資料夾存取權 | plugin 從不讀寫任何檔案。每個共用資料夾都設成**無法存取** |
| File Station、Drive、Photos… | 除 **DSM** 以外全部拒絕。plugin 只呼叫 DSM Web API |
| 個人資料夾 | 用不到。政策允許的話直接停用 |
| SSH／rsync | 從不使用 |
| 從任何地方登入 | 見防火牆一節 |

即使群組本身是特權群組，這樣收緊仍然值得：它讓一組洩漏的憑證**無法**用來透過
SMB 或 Drive 翻你的檔案，而那是「一次事故」和「一場災難」的差別。

### 自己驗證最小權限

這件事目前的誠實狀態是：測試時用的帳號本來就在管理員群組裡，所以那次唯讀探索
證明的是「**管理員可以**」，並沒有證明「**非管理員不行**」。要在你自己的 NAS 上
確認：

```bash
# 先在 DSM 建一個「非管理員」帳號，然後：
bin/pve-syno-api-probe --host <nas> --user <那個帳號>
```

若 API 探索成功、但每一個 LUN 與 target 列表都回 **105（權限不足）**，就表示這個
帳號不夠——而那是預期的結果。若它可以用，請告訴我們：那會是比這份文件更好的答案。

---

## plugin 會呼叫的 API，全部列在這裡

除此之外不呼叫任何東西。這是完整清單，方便你稽核。

| API | 方法 | 用途 |
|---|---|---|
| `SYNO.API.Info` | `query` | 探索路徑與版本範圍。**不需要工作階段** |
| `SYNO.API.Auth` | `login`、`logout` | 工作階段 |
| `SYNO.Core.System` | `info` | 型號、韌體版本、能力閘門 |
| `SYNO.Core.ISCSI.Node` | `list` | NAS 自己的 uuid，作為 storage 的身分 |
| `SYNO.Core.Storage.Volume` | `list`、`get` | 用哪個儲存空間、它的檔案系統、可用空間 |
| `SYNO.Core.ISCSI.LUN` | `list`、`get`、`create`、`set`、`delete`、`clone`、`map_target`、`unmap_target`、`take_snapshot`、`list_snapshot`、`get_snapshot`、`delete_snapshot`、`clone_snapshot` | 一顆 VM 磁碟就是一個 LUN |
| `SYNO.Core.ISCSI.Target` | `list`、`get`、`create`、`set`、`delete` | 節點登入的 iSCSI target |
| `SYNO.Core.ISCSI.Host` | 待確認 | 把 target 限制在你的節點 IQN |
| `SYNO.Core.Network.Interface` | `list` | 找出資料連線的 portal |

plugin 從不呼叫 `SYNO.Core.Share`、`SYNO.FileStation`、`SYNO.Core.User`、
`SYNO.Core.Security` 之下的任何東西，也不呼叫任何套件的 API。

---

## 自動封鎖：保持開啟，並且要知道它在保護你什麼

從測試機讀到的設定：

```json
{"enable": true, "attempts": 3, "within_mins": 5, "expire_day": 1}
```

**5 分鐘內登入失敗 3 次，該 IP 位址被封鎖 1 天。**

這件事比看起來重要。Proxmox VE 大約每 10 秒輪詢每一個 storage，每個節點都會做。
一個密碼設錯的 storage，若沒有特別處理，**大約 30 秒內就會累積 3 次失敗登入**——
然後那個節點就被 NAS 鎖在門外 24 小時。五個節點的叢集就是五個節點。

更麻煩的是，被封鎖之後的症狀**不是**「認證失敗」，而是連線被拒絕——看起來像網路
故障，或像 NAS 掛了。

**所以這個 plugin 在第一次憑證失敗就停。** 被拒絕的憑證——DSM 錯誤碼 400、402、
403、404——只記錄一次，把 storage 標成需要人介入，在設定被改過之前不再重試。
這是刻意訂下的設計規則，不是實作細節，也正是你可以安心讓自動封鎖保持開啟的原因。

若真的被封鎖了：控制台 → 安全性 → 帳號 → 自動封鎖 → 允許／封鎖清單，把位址移除。

---

## 兩步驟驗證

這個 plugin 可以搭配開了 2FA 的帳號，而 Synology 自己的 CSI driver 不行——
這是「晚做」少數佔到便宜的地方。

流程是：第一次登入把一次性密碼和 `enable_device_token=yes` 一起送出，DSM 回傳一個
**device token**；之後每次登入送這個 token，不必再輸入代碼。

```bash
pvesm set <storage> --syno-otp 123456     # 只需一次
# plugin 會保存 device token 並清掉 otp 選項
```

**device token 是憑證。** 它是那個帳號的常設 2FA 旁路：任何拿到它的人都能不用
代碼登入。它的保護等級和密碼相同，而且絕對不可以進到程式庫、技術支援單或截圖裡。

如果你不希望 NAS 上存在一個常設旁路，那就讓這個「專用、沒有資料夾權限、沒有應用
程式權限、被防火牆綁住」的帳號不要開 2FA——那是站得住腳的選擇，而且可以說是更
乾淨的選擇。

---

## 網路

有兩項設定比任何帳號調整都有價值：

1. **防火牆** — 控制台 → 安全性 → 防火牆。DSM 連接埠（5001）只允許來自 PVE 節點
   的位址。plugin 和 NAS 的全部往來都來自那些主機，所以出現在那個連接埠上的其他
   連線都不是這個 plugin。
2. **把資料路徑分開** — iSCSI 流量（3260）應該走自己的網路或 VLAN，而 DSM 的管理
   連接埠不需要從那個網路連得到。

DSM 預設會把工作階段綁在用戶端的 IP 位址上（測試機上
`skip_ip_checking: false`），所以工作階段無法從別處重放，而每個節點也必然各有
自己的工作階段。

另外：**DSM 的工作階段預設閒置 15 分鐘就過期。** plugin 會在過期後重新登入，
那是正常事件，不是錯誤。

---

## HTTPS

DSM 出廠是自簽憑證，所以本 plugin **預設不驗證憑證**（`syno-ssl-verify 0`）。
預設為「驗證」會讓幾乎每一台新安裝的 DSM 根本加不進來，而一個沒有人能用的預設值
保護不了任何人。

如果你有節點驗證得過的憑證——DSM 內建的 Let's Encrypt，或你自己的 CA——就打開它：

```bash
pvesm set <storage> --syno-ssl-verify 1 --syno-tls-ca /etc/ssl/certs/your-ca.pem
```

純 HTTP 一律拒絕。DSM 允許把登入寫成 GET、密碼放在 query string 裡——Synology
自己的 CSI driver 就是那樣登入的——而這個 plugin 不那樣做：那會把密碼寫進 NAS
自己的存取記錄，以及中間每一個代理伺服器。
