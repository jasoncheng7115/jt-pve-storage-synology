# 這個 plugin 需要的 DSM 帳號權限

**不要把 `admin` 帳號給這個 plugin**。建一個專用帳號、把它不需要的東西全部關掉、再限制它能從哪裡登入。這份文件說明怎麼做，也誠實說明 Synology 不讓你限制的那一部分。

以下內容於  在一台 **DS918+** 上（DSM 7.1.1-42962 Update 9）以唯讀方式實測取得。無法用這種方式確認的地方，文中會明說。

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

SAN Manager 的 Web API——`SYNO.Core.ISCSI.LUN`、`SYNO.Core.ISCSI.Target`、`SYNO.Core.ISCSI.Host`、`SYNO.Core.Storage.Volume`——屬於 DSM 核心，不屬於套件。**DSM 沒有任何一個可以單獨授予的「管理 LUN」權限**。沒有 SAN 操作員角色，每位使用者的「應用程式權限」清單裡也沒有 SAN Manager。所以非管理員帳號沒有任何有文件依據的方式能呼叫這些 API。

**這是 DSM 的限制，不是本 plugin 便宜行事**。和相關專案面對的那些陣列相比——那些可以建立範圍限定在儲存區的角色——這確實是一個退步，而你在決定 NAS 的網路配置之前應該先知道這件事。

在管理員群組裡**不代表**也必須給的東西：

| 也要給嗎 | 不用，因為 |
|---|---|
| 共用資料夾存取權 | plugin 從不讀寫任何檔案。每個共用資料夾都設成**無法存取** |
| File Station、Drive、Photos…| 除 **DSM** 以外全部拒絕。plugin 只呼叫 DSM Web API |
| 個人資料夾 | 用不到。政策允許的話直接停用 |
| SSH／rsync | 從不使用 |
| 從任何地方登入 | 見防火牆一節 |

即使群組本身是特權群組，這樣收緊仍然值得：它讓一組洩漏的憑證**無法**用來透過 SMB 或 Drive 翻你的檔案，而那是「一次事故」和「一場災難」的差別。

### 自行驗證最小權限

**這件事現在已經測過了，而本頁先前的文字對「會發生什麼」的預測是錯的**。在測試用 NAS 上建立了一個非管理員帳號並做了探測：它根本沒有走到「LUN 列舉被 `105` 拒絕」那一步。它在**登入**就被拒絕，錯誤 **402**，無論是完全沒有群組，或是加入 `users` 之後。

完整的量測結果，以及仍然可能把範圍縮小的 DSM 介面檢查方式，都在上面那一節——見**這個 plugin 的 DSM 帳號實際上需要什麼**。


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

plugin 從不呼叫 `SYNO.Core.Share`、`SYNO.FileStation`、`SYNO.Core.User`、`SYNO.Core.Security` 之下的任何東西，也不呼叫任何套件的 API。

---

## 自動封鎖：保持開啟，並且要知道它在保護你什麼

從測試機讀到的設定：

```json
{"enable": true, "attempts": 3, "within_mins": 5, "expire_day": 1}
```

**5 分鐘內登入失敗 3 次，該 IP 位址被封鎖 1 天。**

這件事比看起來重要。Proxmox VE 大約每 10 秒輪詢每一個 storage，每個節點都會做。一個密碼設錯的 storage，若沒有特別處理，**大約 30 秒內就會累積 3 次失敗登入**——然後那個節點就被 NAS 鎖在門外 24 小時。五個節點的叢集就是五個節點。

更麻煩的是，被封鎖之後的症狀**不是**「認證失敗」，而是連線被拒絕——看起來像網路故障，或像 NAS 掛了。

**所以這個 plugin 在第一次憑證失敗就停**。被拒絕的憑證——DSM 錯誤碼 400、402、403、404——只記錄一次，把 storage 標成需要人介入，在設定被改過之前不再重試。這是刻意訂下的設計規則，不是實作細節，也正是你可以安心讓自動封鎖保持開啟的原因。

若真的被封鎖了：控制台 → 安全性 → 帳號 → 自動封鎖 → 允許／封鎖清單，把位址移除。

---

---

### 這個 plugin 的 DSM 帳號實際上需要什麼

**已量測，而答案並不好看：這件事沒有被縮小到一個最小集合**。以下是在硬體上確立的，使用一個在擁有者同意下建立並刪除的臨時帳號：

- DSM 7.1.1 只提供三個群組——`administrators`、`http`、`users`——而**其中沒有任何一個是 iSCSI 或 SAN 專用的**。沒有「儲存操作員」這種角色可以授予。
- **完全沒有群組**的帳號在登入時被拒，錯誤 **402**。
- 在 **`users`** 裡的帳號**也**在登入時被拒，**402**。所以並不是「普通使用者可以登入、然後被拒絕儲存呼叫」——它根本無法認證。
- `SYNO.Core.User get` 只回傳 `name` 和 `uid`。權限模型不在那裡公開。
- `SYNO.Core.Group.Member add` 到 `administrators` 回報 `success: true` 卻什麼都沒改，所以連「測試管理員這個情況」都無法用 API 做到。

**所以誠實的立場是：這個 plugin 今天使用的帳號是管理員，而沒有任何更小的可用設定被示範過**。這對正式部署是一個真實的考量，而這裡選擇直接說出來，不掩飾。

#### 已解答：沒有「SAN Manager 權限」可以給

在 DSM **7.4.1-90080**（DS918+）上直接讀了那個帳號的**應用程式**分頁。它列出二十個應用程式：

> AFP · Active Backup for Business（三項）· Audio Station · Central Management System · Cloud Sync · DSM · Download Station · FTP · File Station · Notification Center · Note Station · SFTP · SMB · Synology Photos · Surveillance Station · Synology Drive · Universal Search · rsync · 文字編輯器

**其中沒有任何一項是 SAN Manager、儲存空間管理員或 iSCSI**。所以這個 plugin 需要的存取權不能以「應用程式」的形式允許或拒絕：它是隨 `administrators` 一起來的，沒有更小的東西可以發放。加上前面那些 API 的發現——沒有群組的帳號和放在 `users` 裡的帳號都在登入時被 402 拒絕——這個問題就結束了。這是讀 DSM 自己的介面得到的結論，不是從 API 的沉默推論出來的。

#### 這代表你該做什麼

這個發現不只是一項限制，它同時指出了「現存最小的組態」長什麼樣。那二十個應用程式**每一個都可以**對這個帳號拒絕，所以：

1. 一個**專用**的管理員帳號，除了這個 plugin 之外不給任何東西用。
2. 不給共用資料夾權限，不建立家目錄。
3. 在**應用程式**分頁把每一個應用程式都拒絕。API 是透過 DSM 本身登入的，所以那一項留著，其餘全部拒絕。
4. 開 2FA——前提是你接受在 `/etc/pve/priv/storage/<id>.syno` 裡存放一個常設的裝置權杖。
5. 在控制台 → 安全性 → 防火牆裡以 IP 限制，鎖到那幾個節點。

在這個 DSM 版本上能縮到的就是這樣，而且值得做——這個發現的重點正是：即使非管理員不可行，第 1 到第 5 步仍然是可用的。

在那之前，請把這個帳號視為有特權的：專供這個 plugin 使用、沒有共用資料夾、沒有其他應用程式、如果你接受常設裝置權杖就開 2FA，並且在防火牆中以 IP 鎖定。

## 憑證存放的位置

`/etc/pve/priv/storage/<storage>.syno`，權限 `0600`，而該目錄由叢集檔案系統**只提供給 root**。裡面存放 DSM 密碼、CHAP 密鑰以及 2FA 裝置權杖。因為位於 `/etc/pve` 底下，它會複寫到每個節點，而共用 storage 需要這一點。

它們對 Proxmox VE 宣告為 `sensitive-properties`，正是這一點讓 PVE 在寫入設定之前把它們拿掉，改為交給 plugin。PVE 自己的 CIFS、PBS 和 ESXi plugin 用的是同一套機制。


## 網路

有兩項設定比任何帳號調整都有價值：

1. **防火牆** —控制台 → 安全性 → 防火牆。DSM 連接埠（5001）只允許來自 PVE 節點的位址。plugin 和 NAS 的全部往來都來自那些主機，所以出現在那個連接埠上的其他連線都不是這個 plugin。
2. **把資料路徑分開** —iSCSI 流量（3260）應該走自己的網路或 VLAN，而 DSM 的管理連接埠不需要從那個網路連得到。

DSM 預設會把工作階段綁在用戶端的 IP 位址上（測試機上 `skip_ip_checking: false`），所以工作階段無法從別處重放，而每個節點也必然各有自己的工作階段。

另外：**DSM 的工作階段預設閒置 15 分鐘就過期**。plugin 會在過期後重新登入，那是正常事件，不是錯誤。

---

## HTTPS

DSM 出廠是自簽憑證，所以本 plugin **預設不驗證憑證**（`syno-ssl-verify 0`）。預設為「驗證」會讓幾乎每一台新安裝的 DSM 根本加不進來，而一個沒有人能用的預設值保護不了任何人。

如果你有節點驗證得過的憑證——DSM 內建的 Let's Encrypt，或你自己的 CA——就打開它：

```bash
pvesm set <storage> --syno-ssl-verify 1 --syno-tls-ca /etc/ssl/certs/your-ca.pem
```

純 HTTP 一律拒絕。DSM 允許把登入寫成 GET、密碼放在 query string 裡——Synology 自己的 CSI driver 就是那樣登入的——而這個 plugin 不那樣做：那會把密碼寫進 NAS 自己的存取記錄，以及中間每一個代理伺服器。
