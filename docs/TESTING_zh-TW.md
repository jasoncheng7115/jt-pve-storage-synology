# 測試與驗證

這份文件有兩個任務：說清楚**哪些事情真的驗證過、哪些沒有**，以及提供把後者搬到前者的測試計畫。

它刻意寫得誠實。一個會默默猜測的 storage plugin 比一個會拒絕的更糟，所以每一項陣列端的事實都標明來源，而任何無法確認的事情都會直說。

---

## 來源位階

| 階 | 來源 | 能證明什麼 |
|---|---|---|
| 1 | **實機** | 行為。唯一能回答「那真的刪掉了嗎」的一階 |
| 2 | **Synology 官方 CSI driver**（`SynologyOpenSource/synology-csi`）| 某個 API 存在，以及大致怎麼呼叫 |
| 2 | **OpenStack Cinder 的 Synology driver** | 同上，但是獨立的第二份——而且它知道 CSI 不知道的事 |
| 3 | **Synology 知識中心／SAN Manager 技術規格** | 產品限制 |
| 4 | **DSM Login Web API Guide** | 只有登入與 API 探索。它完全沒有記載任何 SAN API |
| —| 猜測 | 不是一階。不允許出現在程式碼裡 |

兩份第 2 階來源**彼此矛盾**，而矛盾的地方正是有價值的地方。工作階段的處理是最清楚的例子：見下面「工作階段怎麼帶」。

---

## 測試硬體

| | |
|---|---|
| 型號 | DS918+ |
| DSM | 7.1.1-42962 Update 9 |
| 儲存空間 | `/volume1`，**Btrfs**，總量 14301.5 GiB |
| 機器自報的上限 | **`max_iscsiluns` 256、`max_iscsitrgs` 128**、`max_snapshot_per_lun` 256——這是機型自己的數字，不是技術規格表上的 512／256 |
| Target 實作 | `iscsi_target_type` = `lio4x` |
| 註 | 這是一台**正式機**，同時也在跑 Virtual Machine Manager。寫入測試已在專用的 `pvetest-` 名稱前置字串下、取得擁有者同意後執行，建立的每個物件都已刪除，並確認 NAS 回到原本的內容 |

**已經做過的事**：唯讀探索、在專用名稱前置字串下的寫入測試，以及一次把 LUN 掛到 Proxmox VE 節點——下面的 WWID 推導與 multipath 行為就是從那裡來的。模組層（`Synology::API`、`::LUN`、`::Target`、`::Naming`、`::Multipath`、`::Command`、`::ISCSI`）已對這台硬體完整跑過。**PVE plugin 本身還沒有寫**，所以這裡沒有任何東西是透過 `pvesm` 驗證的。

---

## 實機已驗證（2026-08-06）

到 `dev_attribs` 表格為止的每一項都是唯讀取得的。下面標為寫入測試的部分是在專用的 `pvetest-` 名稱前置字串下、取得擁有者同意後執行，建立的每個物件事後都已刪除，並確認陣列回到原本的內容。

### 工作階段怎麼帶——兩份參考實作的做法不同，而其中一份在這裡是錯的

| 載體 | 在 DSM 7.1.1 上的結果 |
|---|---|
| `_sid` 表單參數（Cinder 的做法）| **119，SID not found——每一個呼叫都失敗** |
| `Cookie: id=<sid>` 標頭（CSI 的做法）| 可用 |

而且這個 cookie **不是伺服器設定的**：登入回應把 sid 放在主體裡，完全沒有 `Set-Cookie`，所以 cookie 必須由用戶端自己組出來。用 cookie jar 會得到一個空檔案，然後每個呼叫都回 119——那看起來像登入壞了，但登入是好的。

本 plugin 兩種載體都送。

### 會改變設計的安全設定

| 設定 | 值 | 後果 |
|---|---|---|
| `enable_csrf_protection` | **true** | 每個請求都必須回送登入時取得的 `SynoToken`，否則 NAS 回 **105（權限不足）**——那看起來完全像權限問題。**兩份參考實作都不送這個 token**，所以在這樣設定的 NAS 上兩份都不能用 |
| 自動封鎖 | **開啟：5 分鐘 3 次 → 封鎖 1 天** | 密碼設錯的情況下，正常輪詢大約 30 秒就會讓一個節點被鎖在 NAS 外一整天。見 `DSM-ACCOUNT_zh-TW.md` |
| `timeout` | **15 分鐘** | 工作階段過期是正常事件，不是錯誤。遇 105／106／119 重新登入是常規路徑 |
| `skip_ip_checking` | false | 工作階段綁定用戶端 IP；每個節點必然各有自己的 |

### LUN 的欄位，NAS 實際回報的樣子

```
allocated_size  block_size  create_from  description  dev_attribs
dev_attribs_bitmap  dev_config  dev_qos  direct_io_pattern
flashcache_id  flashcache_status  is_action_locked  location
lun_id  name  restored_time  size  status  type  type_str  uuid
vpd_unit_sn
```

其中三個比其他都重要，而**沒有任何公開用戶端讀取它們**：

- **`vpd_unit_sn` 就是 LUN 的 uuid，一字不差**。那是 SCSI VPD 的單元序號，也就是 Linux WWID 的來源。這代表 LUN 與裝置之間可以靠**核心自己的認定**對應，而不是只靠它被發現的路徑。兩份參考實作都只用 `/dev/disk/by-path`。
- **`restored_time` 存在**，這是「從快照還原 LUN」是一個真實且會被記錄的操作的證據——見未確認登記簿 R-1。
- `lun_id` 和 target 的 `mapping_index` 是**兩個不同的數字**。`mapping_index` **從 1 開始，不是 0**。

### LUN 的 uuid 怎麼變成 Linux 的 WWID

在一台掛著該 LUN 的主機上讀到：

```
scsi-36001405a1b2c3d4d5e6fd4a7bd8c9dd0 -> sdg
VENDOR=SYNOLOGY  MODEL=Storage
SERIAL=a1b2c3d4-5e6f-4a7b-8c9d-0e1f2a3b4c5d     <- 就是 LUN 的 uuid，原封不動
```

關係是確定性的：

```
WWID = "3" + "6001405" + （uuid 把 "-" 換成 "d" 之後的前 25 個字元）
```

`6001405` 是 Linux-IO 的 IEEE 公司識別碼，所以 Synology 的 target 是 LIO 系的——**但這不是原廠 LIO 的行為**。上游的 `spc_gen_naa_6h_vendor_specific()` 用 `hex_to_bin()` 轉換序號，非十六進位字元會被**跳過**，那樣算出來是 `36001405a1b2c3d45e6f4a7b8c9d0e1f2`——而那不是 NAS 產出的值。Synology 是把連字號映射成 `d`，不是丟掉。**照著上游原始碼推論會得到一個很有自信的錯誤答案**，只有實機給了對的。

三個後果：

1. WWID **可以在裝置出現之前就算出來**，所以 multipath map 能確定性地釘住，而且節點能判斷「我找到的裝置是不是我要的那顆 LUN」——不必只相信它是從哪個路徑被發現的。
2. **uuid 的最後 11 個字元被丟掉了**。所以 WWID 不是 uuid 的無損函式、不可反推，而且兩個只在尾端不同的 uuid 會撞同一個 WWID。隨機 uuid 下機率可忽略，但規則不變：算出來的值是**交叉核對**用的，最終認定要由核心自己的識別決定。
3. multipath `conf.d` drop-in 需要的兩個字串是 `vendor "SYNOLOGY"` 與 `product "Storage"`。**兩個都不可能從 NAS 的 API 取得**——它們是 SCSI INQUIRY 的回應。猜錯會讓 drop-in 靜靜地不生效，而 `no_path_retry` 不生效就代表所有路徑消失時會無限排隊。

**一個樣本不足以證明一條規則**。上面的規則精確重現了一個實測到的 WWID，這足以拿來當交叉核對，但不足以拿來依賴。另外兩顆 LUN 的預測值記錄在非公開的文件裡，等第一次掛上測試 LUN 時對照——如果規則是錯的，這一節會改，而 plugin 不論如何都會從核心讀回 WWID。

如果你手上有掛載中的 Synology LUN，這是五秒鐘就能做的貢獻：

```bash
# uuid 從 SAN Manager 或探索工具取得；WWID 在掛著它的主機上讀
ls -l /dev/disk/by-id/ | grep -i 6001405
```

### 一個不只是「未驗證」、而是「已驗證為不完整」的過濾條件

Synology 的 CSI driver 列出 LUN 時會送一個明確的十二種型態過濾條件（`BLOCK`、`FILE`、`THIN`、`ADV`、`SINK`、`CINDER`…、`BLUN`、`BLUN_THICK`…）。在測試機上，**那個過濾條件回傳 3 顆 LUN，而不帶過濾的列表回傳 4 顆**。被藏起來的那一顆是：

```
type 295，VDISK_BLUN，120 GiB —— 一個 Virtual Machine Manager 的虛擬磁碟
```

它的 120 GiB 和其他東西吃的是同一個儲存空間，所以任何相信那個過濾條件的用戶端會少算這麼多已配置空間，而且完全看不到這個物件。

**所以本專案從不送型態過濾條件**。它不帶過濾地列出，然後在本地用名稱比對——而名稱本來就是它唯一信任的所有權判準。探索工具現在會跑兩次列表並回報過濾條件藏了什麼，因為下一台 DSM 可能藏的是別的型態。

這是那條通則的具體版本：**一個 plugin 要求過濾過的清單，必須被檢查它真的過濾了什麼**，而「本來就沒有」和「被過濾掉了」在回應裡是分不出來的。

### 建立回報失敗，卻還是把 LUN 建出來了

可穩定重現。名稱剛好 **255 個字元**的 LUN 會被錯誤碼 **18990068** 拒絕——而 LUN 還是被建立了：完整名稱、正確容量、`status: normal`，完全可用。到 256 個字元時拒絕是乾淨的（**18990503**，名稱不合法），什麼都不會建。

```
建立，255 字元名稱  ->  REFUSED 18990068
                    ->  ……而且陣列上多了 1 顆 LUN
建立，256 字元名稱  ->  REFUSED 18990503，什麼都沒建
```

**所以一個失敗的建立絕對不能單憑它自己的回答就相信**。任何建立失敗之後，plugin 都要按名稱查一次，然後決定接管它或刪掉它。少了這一步，每一次這種失敗都會漏掉一顆 Proxmox VE 完全沒有紀錄的 LUN：空間沒了、沒有任何東西指向它，而下一次嘗試又會再建一顆。

這也是為什麼名稱長度限制要在**送出請求之前**就檢查，而不是交給 NAS 去拒絕。

### 倒回在這裡是安全的，而那不是理所當然

`restore_snapshot` 收 **`src_lun_uuid` 與 `snapshot_uuid`**。只送快照會被 **18990508** 拒絕，所以 LUN 也必須指名。

量了三件事，而且這三件事全都必須是這個答案，倒回才可能出貨：

| 問題 | 答案 |
|---|---|
| LUN 的 uuid 會變嗎？| **不會**。所以 SCSI 序號與 WWID 不變，節點不會突然看到另一顆磁碟 |
| 比還原點更新的快照會活著嗎？| **會**。還原到三個之中最舊的那一個，三個都還在 |
| 有被記錄嗎？| `restored_time` 從 0 變成還原當下的 epoch 秒 |

第二個答案值得停下來看，因為相關專案必須**拒絕**越過較新快照的倒回——在那些陣列上較新的快照會被銷毀，而讓 PVE 默默做那件事的 plugin，等於刪掉使用者還看得到的快照。這裡什麼都不會被銷毀，所以 `volume_rollback_is_possible` 不需要那道限制，一個 storage 也可以反覆倒回。

### 快照與複本之間沒有依賴鏈

這個家族裡其他每一個陣列，都會拒絕刪除「有別的東西依賴它」的物件，而那兩種拒絕都造成過真實的缺陷。Synology 兩種都不拒絕：

| 嘗試 | 結果 |
|---|---|
| 刪除有快照的 LUN | **允許**。快照跟著走——對已刪除的 uuid 呼叫 `list_snapshot` 回 18990531，所以不會留下孤兒 |
| 刪除某個複本的來源快照 | **允許**，而且複本維持 `normal`、可以繼續用 |
| 刪除**已對應到 target** 的 LUN | **允許** |

所以相關專案需要的「先清依賴」在這裡不必做——但第三列把工作轉到 plugin 身上：**沒有任何東西阻止一顆已對應的 LUN 被刪除**，所以「刪除前先解除對應」完全是這個 plugin 的責任。一顆在還被對應時就被刪掉的 LUN，會讓每個掛過它的節點留下一個什麼都不回答的裝置。

### 從快照複製出來的是精簡的

`clone_snapshot` 產生的是 `allocated_size: 0` 的 `BLUN`——節省空間，所以連結複本與範本是真的便宜，不是完整複製。

### `mapping_index` 會被重用，所以裝置路徑不能當身分

```
把三顆 LUN 對應到同一個 target   -> 編號 1、2、3
解除中間那一顆                   -> 編號 1、3
對應第四顆 LUN                   -> 編號 1、2、3   <- 新的 LUN 拿到了編號 2
```

**被釋放的編號會交給下一顆 LUN**。一個還握著 `...-iscsi-<iqn>-lun-2` 舊裝置的節點，會發現那個路徑現在指向一顆完全不同的 LUN。這屬於「寫到別人的磁碟」那一類錯誤，而且用一般操作就到得了：卸離一顆磁碟、掛上另一顆。

兩份公開的參考實作都只用 `/dev/disk/by-path` 認裝置。**在這個陣列上那不安全**。這就是為什麼上面那條 WWID 推導是承重的，不是方便而已：一個裝置只有在**核心自己的識別**與被要求的那顆 LUN 相符時才會被接受。

### 對應是「加入」，解除對應只動指定的那些

| 呼叫 | 行為 |
|---|---|
| 對一顆已對應到別處的 LUN 送 `map_target` 一個 target | **加入**。既有的對應仍然存在 |
| `unmap_target` 一個 target | **只**移除那一個 |

這和 Unity 的 `hostAccess` 正好相反——那邊清單是被取代的，送一個 host 就會把叢集裡其他每個節點解除對應。這裡的逐節點對應照原樣寫就是安全的。plugin 仍然會讀出現有清單並送出聯集，因為一個在一版韌體上量過一次的行為不是承諾。

### 並行與工作階段

- **十六個同時發出的建立全部成功**，耗時 15 秒，而陣列的內容與 API 回報的一致——沒有遺失也沒有重複的 LUN。每個建立約 1 秒，看起來 DSM 內部是序列化的，這也解釋了 Cinder 為什麼把每個請求都包在行程級鎖裡；但這裡沒有任何東西為了正確性需要那個鎖。
- **同一帳號的第二次登入不會擠掉第一次**。兩個 sid 同時有效，所以共用一個帳號的叢集節點不會互相踢掉對方——而錯誤碼 107「被重複登入中斷」本來讓這件事很值得擔心。

### 核心端，用第二個樣本確認

一顆 2 GiB 的精簡 LUN 被對應到一個專門建立的 target，並掛到一台 Proxmox VE 節點。從第一個樣本推導出的 WWID 規則精確預測了答案：

```
LUN uuid            13a3cd1e-f296-4d4b-b712-a85c139f9dac
預測的 WWID          3600140513a3cd1edf296d4d4bdb712da
scsi_id -g -u       3600140513a3cd1edf296d4d4bdb712da     <- 完全相同
/sys/.../device/wwid  naa.600140513a3cd1edf296d4d4bdb712da
```

兩個 uuid 毫不相關的獨立樣本現在一致，所以這條推導可以當交叉核對用。最終認定仍然由核心的答案決定。

裝置對自己的描述：

| | |
|---|---|
| Vendor | `SYNOLOGY`（8 位元組）|
| Product | `Storage`（16 位元組，以空白填滿——`Storage         `）|
| Revision | `4.0` |
| `TPGS` | **1**——裝置宣告支援隱式 ALUA |

### multipath 的發現，這改變了裝置的定址方式

**multipath 沒有任何內建的 Synology 設定。**`multipathd show config` 裡完全沒有 `SYNOLOGY` 條目，所以本 plugin 提供的 `conf.d` drop-in 不是調校上的講究——沒有它，裝置會落回通用預設值，而在測試節點上那些預設值包含 `no_path_retry "queue"`，正是那個會讓「所有路徑消失」變成殺不掉的當機的設定。

**不能假設 `/dev/mapper/<wwid>` 存在**。測試節點設了 `user_friendly_names yes`，所以 multipath 把 map 命名為 `mpathc`。相關專案的 `path()` 回傳 `/dev/mapper/<wwid>`，而在這裡那個路徑根本不存在。**一直都存在**的是 dm-uuid 連結：

```
/dev/disk/by-id/dm-uuid-mpath-3600140513a3cd1edf296d4d4bdb712da -> ../../dm-9
```

所以裝置要靠它定址，或是從 WWID 反查 map 名稱——絕不能假設節點管理者選了哪一種命名政策。把 `user_friendly_names no` 設成全域，會把同一節點上**其他廠商的** map 一起改名，而本專案不做那件事。

另外值得知道：這個節點上掛載的裝置**完全沒有出現 `/dev/disk/by-id/scsi-*`**，儘管同樣型態的 LUN 在另一台主機上有。它也不是可靠的把手。

還有，拆掉一個 map 時，`multipath -f` 可能回答 **「device not found」**，因為 `fail_if_no_path` 已經讓 multipathd 先把它移除了。那是成功，不是錯誤。

### 複製的時間，以及為什麼 `allocated_size` 不能用來算容量

複製一顆內含 512 MiB 真實資料的 LUN：

| | |
|---|---|
| `is_action_locked` 解除時間 | **3.5 秒**（空 LUN 是 0.0 秒）|
| 複本回報的 `allocated_size` | **512 MiB** |
| `/volume1` 實際被消耗的空間 | **0 位元組** |

所以這個複本是 **reflink**：區塊是共用的，而 `allocated_size` 對兩顆 LUN 都算了一次。**把 `allocated_size` 加總會高估使用量，而且高估的幅度沒有上限**——一個範本帶二十個連結複本，看起來會像消耗了二十倍。所以容量來自儲存空間自己的 `size_free_byte`，絕不是把 LUN 加起來，而 `status()` 就是這樣做的。

同一顆 LUN 的快照不論內容多少，都在 **0.20 秒**完成。

**空間是延遲回收的**。刪除一顆寫入過 512 MiB 的 LUN 之後，過了幾分鐘儲存空間的可用容量仍然沒有變。什麼都沒有遺失——Btrfs 會用它自己的步調還回來——但一個預期「刪除後可用空間立刻上升」的 plugin 會下錯結論，而 `syno-min-free` 這道守衛也不能被它嚇到。

### R-14：非管理員帳號連登入都過不了

一個剛建立的非管理員帳號在**登入本身**就被 **402** 拒絕，還沒機會嘗試任何 SAN API——所以這次執行無法區分「碰不到 SAN API」與「根本登不進 DSM」。要再往下釘，需要在介面上手動授予 DSM 應用程式權限，而每試一次就是一次登入嘗試，對著一個自動封鎖政策——**5 分鐘 3 次失敗就封鎖 1 天**——所以刻意就此停手。`DSM-ACCOUNT_zh-TW.md` 的實務建議不變：帳號必須是管理員，而其他一切都應該從它身上拿掉。

那次嘗試順帶得到兩個值得留下的發現：

- 對 `SYNO.Core.User` `create` 傳 `expired=now`，會產生一個存在但無法登入的帳號。症狀是一個看起來像權限問題的 402——一個被猜出來的參數，默默建立了一個壞掉的帳號。
- `SYNO.Core.User` `set` 帶 `expired=never` **回報成功、卻什麼都沒改**。又一個不能照字面相信的 API 回應。

### 兩個節點，以及一個屬於 PVE 架構而非缺陷的限制

在一個兩節點叢集上驗證（`pc-pve1` 核心 7.0.2、`pc-pve2` 核心 7.0.14，所以不是彼此的複製品）：

| | |
|---|---|
| 兩個節點都回報 storage `active`，容量完全相同 | 是 |
| `shared` 被強制為 1，而且不會出現在 `storage.cfg` 裡 | 是 |
| **同一帳號、兩個 IP、兩個 DSM 工作階段同時存在** | 是——R-13 在真實叢集裡得到解答：它們並存，沒有任何一個被擠掉 |
| `max_sessions = 0` 的同一個 target 上兩個 iSCSI 工作階段 | 是，NAS 兩個都列出來 |
| 兩個節點從同一顆 LUN 讀到相同的位元組 | 是 |
| 離線遷移 | 2 秒，沒有複製磁碟 |
| **線上遷移** | **停機 3 毫秒**，而且來源節點在目的節點接手時釋放了裝置 |
| 兩次遷移之後資料完好 | 是，sha256 相同 |
| VM 執行中拍快照，之後倒回 | 是，資料正確 |

#### `find_multipaths` 是逐節點的政策，而它決定 map 存不存在

這是只有第二個節點才能產生的發現。`pc-pve1` 是 `find_multipaths no`，所以 multipath 為每個裝置都建 map，一切正常。`pc-pve2` 是 `find_multipaths yes`，那**只**會為「有兩條以上路徑」或「WWID 已經在 `/etc/multipath/wwids` 裡」的裝置建 map。單一 portal 的情況下因此**完全沒有 map**——工作階段是通的、by-path 裝置在那裡，而這個 plugin 交出去的路徑指向不存在的東西。

所以 plugin 不再期望 map 會自己出現。它會執行 `multipath -a <wwid>`，那會在那個檔案裡剛好附加一個 WWID，然後按 WWID 要求建立 map，而如果它仍然沒有出現就**讓啟用失敗**，而不是讓一台 VM 對著一個不存在的路徑開機。絕不用 `multipath -A`，也絕不用 `-w`／`-W`——那會重寫整個檔案，把其他廠商的條目一起丟掉。

#### 移除共用 storage 會在其他節點留下工作階段

`on_delete_hook` 只在**一個**節點上執行——就是打 `pvesm remove` 的那個。它會移除 target 並釋放那個節點的工作階段。其他節點永遠不會被通知。

**而 `deactivate_storage` 救不了你，因為根本沒有東西呼叫它**。這是在 Proxmox VE 9 上對整個 `/usr/share/perl5/PVE` 目錄樹驗證過的：只有 `Storage.pm` 裡的分派函式和各 plugin 自己的實作存在，而 `pvestatd` 和 API 都不會去呼叫它。這個專案自己先前的文字曾聲稱停用 storage 會讓「每個節點在下一次輪詢時停用」——那是錯的，而相關專案 NetApp 那支早就發現並修正過完全相同的說法。

所以那個殘留物——一個死掉的工作階段，加上一個指向已不存在 target 的失敗 map——是**管理者的工作範圍**，而下面那段程序是真正要做的事，不是形式：

```bash
# 1. 在「每一個」節點上，趁 storage 還在設定裡的時候：
pve-syno-reap --storage <storage>            # 試跑，顯示留下了什麼
pve-syno-reap --storage <storage> --remove   # 然後真的處理

# 2. 之後才在其中一個節點上：
pvesm remove <storage>
```

`pve-syno-reap` 存在的理由是那個「永遠不會被通知」的節點：**被硬重置的節點根本不會執行 `deactivate_volume`**，所以它的追蹤檔會留著一筆對應「已不再掛載」LUN 的記錄。這個工具預設是試跑，絕不動到正在使用中的裝置，而且對任何無法確定狀態的東西是跳過，不是假設。

它原本也是為了第二種情況而寫，而**那種情況已經重新量測過，不再發生**——見下面「遷移不再留下 map」。

留下來的是一個死掉的工作階段和一個失敗的 map，指向一個已經不存在的 target。無害，但會累積。**要乾淨地移除一個 storage：**

```bash
pvesm set <storage> --disable 1     # 每個節點會在下一次輪詢時停用
# 等到所有節點的 storage 都變成 inactive，然後：
pvesm remove <storage>
```

如果還是留下了，在那個節點上：

```bash
multipathd disablequeueing map <map>
dmsetup message <map> 0 fail_if_no_path
multipath -f /dev/mapper/<map>
iscsiadm -m node -T <iqn> -p <portal> --logout
iscsiadm -m node -T <iqn> -p <portal> -o delete
```

### 終於是真的 multipath——以及被我觸發的自動封鎖

在此之前的每一次測試都是單路徑。把 NAS 的兩個位址都設為資料 portal 之後：

```
mpathl (36001405...) dm-9 SYNOLOGY,Storage
size=1.0G features='1 queue_if_no_path' hwhandler='1 alua' wp=rw
`-+- policy='service-time 0' prio=50 status=active
  |- 6:0:0:1 sdc 8:32 active ready running     <- 經由 192.0.2.10
  `- 7:0:0:1 sdd 8:48 active ready running     <- 經由 192.0.2.11
```

**故障切換，全程持續讀取**。在節點端用 `nft` 擋掉其中一個 portal：

| | |
|---|---|
| 被擋住的路徑 | 約 15 秒內變成 `failed faulty offline` |
| 存活的路徑 | 維持 `active ready running` |
| **失敗的讀取** | **60 次裡 0 次** |
| 解除封鎖後的恢復 | 約 10 秒自動恢復 |

`path_checker tur`、`failback immediate`、`polling_interval 5`——drop-in 正在做它該做的事。

**管理連線中斷不會把資料一起帶走**。只擋 DSM 的 5001 連接埠、放行 3260：storage 回報 `inactive`，節點上其他 storage 不受影響，`pvesm status` 只增加大約一個 `syno-status-timeout` 的時間，警告只出現**一次**而不是每次輪詢都出現，磁碟仍然可讀，而解除封鎖後它自己恢復了。

#### 憑證鎖定原本沒有作用，而查出這件事的代價是一次真實的封鎖

被拒絕的憑證只能試**一次**。那個鎖定原本是一個物件欄位——而 plugin 每次呼叫都建立新的 API 物件，所以它跟著物件一起消失了。三次輪詢就是三次失敗登入。

它現在是 `/run` 底下的一個檔案，而且驗證過了：五次輪詢之中，只有一次真的送到 NAS，另外四次在本地就被拒絕。

**但這個測試本身觸發了自動封鎖**，而這件事值得盡可能直白地記下來：

```
從被測試的節點：  登入 -> 407   （IP 被封鎖）
從另一個節點：    登入 -> OK    （封鎖是按來源位址計算的）
iSCSI 資料路徑：  不受影響——既有工作階段與 I/O 都繼續
```

5 分鐘內三次失敗登入，該位址被封鎖**一天**。現在保護機制是有效的；而「為什麼需要它」的示範並不是模擬。如果真的發生了：**控制台 → 安全性 → 帳號 → 自動封鎖 → 允許／封鎖清單**，把位址移除。整個過程中資料路徑都照常運作，而這正是它容易被忽略的原因。

**移除該筆項目會立刻恢復存取**——這是在移除之後，從原本被封鎖的那個節點做一次登入確認的，成功了。不需要等 `expire_day` 過期，也不需要重新啟動 NAS 或節點上的任何東西。

### 名稱規則

| | |
|---|---|
| 長度 | 200 字元完全接受。255 會「被拒絕但仍建立」，256 以上乾淨拒絕。200 到 255 之間的確切上限沒有再往下釘，因為這裡沒有任何東西需要那麼長的名稱 |
| 合法 | `-` 連字號、`.` 點、`:` 冒號、大寫、數字 |
| **被拒絕**（18990503）| **`_` 底線**、空格、`+`、`@` |

**底線這件事很重要**。Proxmox VE 的 storage id 可以含底線，而相關專案會把 storage id 折進陣列物件的名稱裡——所以在這裡折疊不能用 `_`，含底線的 storage id 必須被轉成合法字元。而那會把相關專案踩過的撞名問題帶回來：兩個不同的 storage id 折成同一個前置字串，然後彼此都看得到、也刪得掉對方的磁碟。所以「拒絕第二個這樣的 storage」那道檢查，在這個陣列上不是可選的。

### 容量粒度：沒有粒度，而且文件寫的最小值並未被強制

每一個要求的容量都被**精確**建立，任何邊界都沒有進位：

```
1 GiB + 1 byte、1 GiB - 1 byte、1 GiB + 512、3 GiB + 12345   全部精確
100 MiB   精確          1 byte   精確
```

這比這個家族裡其他任何陣列都單純——完全不需要對齊運算。但後半段要注意：知識中心記載**最小 LUN 容量 1 GB**，而 **API 並不強制**。一顆 1 位元組的 LUN 被毫無異議地建立了。所以那個最小值是 plugin 自己要守的，而一個接受極小磁碟的 storage 等於在依賴沒有文件的行為。

### 建立之後的 `is_action_locked`

一顆 1 GiB 精簡 LUN 在 **1.2 秒**後解鎖，而在建立之後**完全不等**就送出的刪除成功了。所以這個鎖不是下一個操作的全面閘門；該輪詢的地方（複製）要輪詢，而不是到處都假設它會擋。

### `dev_attribs`——真實的鍵名

從一顆既有 LUN 讀到的：

| 鍵 | 完整配置 LUN 上的值 | 意義 |
|---|---|---|
| `emulate_3pc` | 1 | XCOPY／第三方複製 |
| `emulate_tpws` | 1 | WRITE SAME |
| `emulate_caw` | 1 | ATS／Compare and Write |
| **`emulate_tpu`** | **0** | **UNMAP／discard——空間回收** |
| `emulate_fua_write` | 0 | |
| `emulate_sync_cache` | 0 | |
| **`can_snapshot`** | **0** | 到底能不能拍快照 |

這改變了建立 LUN 的方式：`can_snapshot=1` 與 `emulate_tpu=1` 必須明確送出，否則得到的是一顆拍不出快照、而且永遠不會把釋放的空間還回去的 LUN。**CSI 的 `dev_attribs` 完全由呼叫端給、自己一個預設都沒有；Cinder 一個都不送**。兩份都不可能告訴我們這件事——是實機告訴我們的。

### Target

`max_sessions` **預設是 1**，而停在 1 的 target 只容許一個節點登入。任何要讓 PVE 叢集共用的 target 都必須設成 0。

Target 的 IQN 裡嵌的是**建立當時**的 NAS 主機名稱——測試機上有帶著兩個不同主機名稱的 target，因為它改過名。所以絕對不可以用「現在的主機名稱」去推導 IQN，再拿去和既有的 target 比對。

### API 範圍

公佈 1184 個 API。SAN 相關全部在 `entry.cgi`、全部 `requestFormat=JSON`（**每個參數都必須 JSON 編碼**）、全部只有 v1：`SYNO.Core.ISCSI.{LUN,Target,Node,Host,FCTarget,Lunbkp,Replication,VMware}`、`SYNO.Core.Storage.{Volume,Pool,iSCSILUN}`。`SYNO.API.Auth` 是 v1-7。

`SYNO.Core.ISCSI.Host`——IQN 存取控制物件——**存在且會回應**（`{"hosts":[]}`）。兩份參考實作都不知道它在那裡。

這個型號上沒有 `SYNO.San.Nvme.*`，所以它不支援 NVMe-oF。

---

### 快照名稱：NAS 什麼都不拒絕，而 PVE 才是比較嚴的那一端

「快照名稱是自由的」這句話被斷言了很久。2026-08-07 實測，而它自由的程度讓驗證變得沒有必要：

| 試了什麼 | 結果 |
|---|---|
| 40 個字元（PVE 自己的上限）| 接受 |
| 64、128、**256** 個字元 | 接受 |
| `_` `+` `@` `/` `%` `:` 以及**空格** | 全部接受 |
| **開頭是連字號** | 接受 |
| 中文字 | 接受 |

這和 LUN 名稱是不同的規則——LUN 名稱會用 18990503 拒絕 `_`、空格、`+`、`@`。這裡不需要任何淨化處理——而更有用的是，**PVE 才是比較嚴的那一端**：`pve-snapshot-name` 是 `pve-configid` 加上 40 字元上限，而 `CONFIGID_RE` 是 `[a-z][a-z0-9_-]+/i`。所以能到達這個 plugin 的快照名稱，只可能是「一個字母開頭，後面接字母、數字、底線、連字號」，最長 40——那是 NAS 所接受範圍的嚴格子集。不存在任何 PVE 能產生、而 NAS 會拒絕的組合。

### 快照名稱在 SAN Manager 上看不到，所以把它放進描述

SAN Manager 的快照清單顯示的是**時間、一致性狀態、描述、狀態、鎖定——完全沒有名稱欄位**。`name` 這個欄位在 API 裡存在，plugin 也是用它比對的，但看著 DSM 的管理者看不到它。

描述原本是 `Proxmox VE <storage>`，所以同一個 storage 上每一顆磁碟的每一個快照，在介面上看起來都一模一樣，而管理者真正會有的那個問題——**這一列是哪一個 PVE 快照？**——在不回到 PVE 比對時間戳的情況下沒有答案。

它是以這類事情被發現的方式被發現的：Jason 拍了一個叫 `install1` 的快照，打開快照清單，在任何地方都找不到那個名稱。它在那裡。只是 DSM 不顯示它。描述現在是 `install1 (Proxmox VE syno-nas2)`，並且用四種不同形狀的名稱從 NAS 讀回來驗證過。

### R-25 已有答案，由別人叢集上的一個快照解決

`create_time` 是 **epoch 秒**。2026-08-07 在 Jason 透過 Proxmox VE 介面拍的一個快照上量到：

| | |
|---|---|
| `create_time` | `1786070747` |
| 換算成 epoch 秒 | `2026-08-07 02:45:47 UTC` |
| PVE 顯示的時間 | `2026-08-07 10:45:46` 本地，UTC+8 = `02:45:46 UTC` |

一秒之內吻合。這件事之所以無法用唯讀方式確定，是因為 **LUN 根本沒有 `create_time` 這個欄位**——只有快照有，而測試用的 NAS 上沒有任何快照。它需要硬體上真的存在一個快照，而這正是登記簿存在的意義。

同一次讀取也確定了欄位名稱，那些名稱先前是從參考實作推斷的，不是觀察到的。`list_snapshot` 回傳的是 **`name`** 和 **`uuid`**——不是 `snapshot_name` 和 `snapshot_uuid`，那是第一次探測所假設的，結果拿到 `None`。plugin 本來就是用 `name` 和 `uuid` 比對的，所以 plugin 是對的；錯的是那次探測。完整欄位：

```
create_time  snapshot_time  name   uuid   parent_uuid  parent_lun_id
snapshot_id  taken_by       type   status  total_size  mapped_size
root_path    description    version  is_app_consistent  is_user_locked
```

`taken_by` 一字不差地回傳 `jt-pve-storage-synology`，而且是在一個這個專案從來沒有碰過的叢集上——這是所有權閘門在真正重要的地方運作，不是在測試裡。

### R-14 實機探測：一個普通帳號連認證都過不了

在擁有者同意下，在 NAS 上建立一個臨時帳號、探測、然後刪除。兩個群組在前後完全逐字相同。

| 步驟 | 結果 |
|---|---|
| DSM 7.1.1 上存在的群組 | 只有三個：`administrators`、`http`、`users`。**沒有任何 iSCSI 或 SAN 專用的群組** |
| 新帳號，完全沒有群組 | **登入被拒，錯誤 402** |
| 加入 `users`（從群組那一側確認過成員身分）| **登入仍然被拒，402** |
| `SYNO.Core.Group.Member add group="administrators"` | **回報 `success: true`，而什麼都沒做** |
| 對該帳號執行 `SYNO.Core.User get` | 只回傳 `name` 和 `uid`——完全沒有任何權限欄位 |
| 這個 plugin 使用的帳號（`dev`）| 在 `administrators` 裡 |

所以無法用 API 隔離出最小權限集合，而探測就停在這裡，不去對一台正式 NAS 上未公開的模型做猜測。

**這對文件的影響**：誠實的說法不是「需要管理員」——那件事也從來沒有被示範過——而是**一個普通 DSM 使用者根本無法認證**，而那道閘門是 DSM 只透過自己的介面開放的。R-14 維持開啟，而剩下那一步被記下來成為「要在 UI 裡確認」而不是「透過 API 確認」的事。

#### 第三個回報成功卻沒做事的 DSM API

`SYNO.Core.Group.Member/add` 對 `administrators` 回答 `success: true`，而成員清單——從群組自己那一側讀回來——沒有改變。同一個呼叫對 `users` **確實**生效了，所以不是這個方法壞掉，而是它對有特權的那個情況無聲地拒絕。

現在總共三個：

| 呼叫 | 回報 | 實際 |
|---|---|---|
| `SYNO.Core.ISCSI.LUN create` 帶 255 字元名稱 | 失敗（18990068）| **建立了那顆 LUN** |
| `multipath -w <wwid>`（multipathd 執行中）| `wwid ... removed` | 什麼都沒做 |
| `SYNO.Core.Group.Member add` 到 `administrators` | `success: true` | 什麼都沒做 |

**要驗證結果，不是驗證回答**。規則 35 說 `success` 是唯一的成功；而這幾個說的是，當結果可以獨立讀回來時，連 `success` 都還不夠。而且使用者那一側的 `additional=["groups"]` 對一個**確實**在群組裡的帳號回傳空清單，所以「你問哪一側」也很重要。

### 節點故障、圍籬與接手——需要讓一個節點失效才能做的測試

在 pc-pve2 上執行，Jason 同意可以中斷它。整個過程叢集維持法定人數（3 之中的 2），而他自己在 pve3 上的 HA 資源完全沒有被動到。

| 測試 | 結果 |
|---|---|
| **正常重開機**，VM 執行中且 LUN 已掛載 | PVE 在關機時停止 VM，plugin 解除追蹤；節點回來後**沒有殘留 map、沒有殘留工作階段、追蹤檔為空**。VM 重新啟動，資料完好 |
| **硬重置**（`sysrq-trigger b`），完全沒有清理 | 節點回來後沒有殘留 map 或工作階段——重開機會清掉核心狀態——但留下一筆**永遠不會有東西移除的追蹤記錄** |
| **HA 圍籬**，VM 交給 `ha-manager` 管理 | pve2 在圍籬時間窗內就重開並重新加入，所以 HA 在原地重新啟動服務而不是遷移。儲存自己重新掛上，經過一次帶 fsck 的當機開機後資料完好 |
| **在當掉的節點還沒回來時接手** | pve1 在 **3.6 秒**內啟動了 VM，而 pve2 已經死了、**它的工作階段仍然登記在 NAS 上**。Guest 開機，舊資料完好，新資料寫入成功 |
| 接手之後 pve2 回來 | 儲存 `active`，沒有 map、沒有工作階段，而且**沒有**去爭奪那顆磁碟 |

接手那一項才是關鍵。在當機的那一刻，一個 `max_sessions=0` 的共用 target 上有**兩個已連線的工作階段**，而存活的節點沒有等任何東西逾時就掛上了那顆 LUN。這正是正式叢集所依賴的性質，而它從來沒有被示範過。

#### 一次當機會留下一筆追蹤記錄，而它不是孤兒

硬重置暴露了一個缺口。`WwidState` 記錄這個節點掛上了什麼；`deactivate_volume` 負責移除那筆記錄。被硬重置的節點永遠不會執行它，所以那筆記錄留了下來——而那顆 LUN 在 NAS 上仍然存在，所以 `orphans` 正確地**不會**回報它。原本永遠不會有東西去清掉它。

它不危險：每個使用者在動作之前都會重新檢查裝置是否存在。但它是一筆聲稱「這個節點持有某個東西」而實際上沒有的記錄，而 `deactivate_storage` 會把非空的追蹤檔讀成「還在使用中」。

`reap_orphans` 現在把它當成一個獨立的情況處理，而檢查用的是 `map_is_gone`——**不是** `device_path_for_wwid`，後者刻意把「沒有裝置」和「stat 沒有回來」都收斂成 undef。用它來解除追蹤，正好會是上一個版本剛修掉的那個錯。只有確認為「已消失」才會解除任何追蹤。

這件事留給管理者，而不是放在 `activate_storage` 路徑上做，因為那條路徑不得改動任何東西——所以節點當機之後，值得跑一次 `pve-syno-reap`。它會在試跑中被回報出來，所以沒有人需要猜。

### 正式環境整備測試，以及持有叢集層級鎖的代價

`cluster_lock_storage` 會把同一個 storage 上的每一次配置**在整個叢集範圍內**序列化。所以一次配置花多久，其他節點就要等多久——而在三個節點同時發出十五個配置時，其中一個在等鎖時失敗了。

先量測，再修正：

| 每次配置 | 之前 | 之後 |
|---|---|---|
| 實際耗時 | 3.6 秒 | **2.16 秒** |
| 開啟的 DSM 工作階段 | 2 | **1** |
| HTTP 請求 | 17 | **12** |
| 完整 `LUN list` 呼叫 | **3** | **1** |

一次配置做三次列舉，而在只有**七**顆 LUN 的 NAS 上每次約 0.6 秒——而那份清單會隨著 NAS 上**所有**LUN 成長，不只是這個 storage 的，因為 types 過濾條件從來不送。它們來自：

- `find_free_diskname` → `list_images`，而它會**自己開一個 DSM 工作階段**：第二次登入、第二次 API 探索、第二次登出，全都在鎖裡面
- `assert_room_for_lun` → 又一次列舉，只為了一個數量
- `warn_if_near_lun_limit` → 又一次列舉，只為了一個警告

現在 `alloc_image` 只取一次，然後傳給三者。`find_free_diskname` 接受一個選擇性的清單參數；其他所有呼叫者的行為和基底類別完全一樣。而 `wait_unlocked` 原本用 `sleep 1` 輪詢，登記簿記錄的鎖清除時間是 **0.20 秒**——所以五分之一秒要花掉整整一秒，每一次建立、每一次快照，而且都在鎖裡面。現在它以 0.2 秒輪詢。

之後三個節點同時發出十五個配置，37 秒內全部完成，沒有失敗，也沒有重複名稱。

#### 在另一個修正裡對三值答案取否定

`_detach_local` 新增的殘留路徑移除原本寫成 `if (!map_is_gone($wwid))`。`map_is_gone` 回傳 **1 / 0 / undef**，而 undef 的意思是「那個 stat 沒有回來」——所以單純取否定會把「無法判斷」讀成「還在」，於是**在沒有任何東西確認過的狀態下刪掉 sd 裝置。**

這不是理論。`qm stop` 之後接 `qm rollback` 就失敗了：

```
storage 'pvesyno': no device for 'pve-pvesyno-vm-9990-disk-0' appeared on this
node after logging in to iqn.2000-01.com.synology:pve-pvesyno-tgt
```

裝置在一個 undef 上被移除了，而重新掃描沒有及時把它們找回來。規則 12 在同一個小時內寫下的修正裡被打破，而只有實際執行才看得出來。那個分支現在要求 `defined $gone && !$gone`。

#### 其餘的測試

| 測試 | 結果 |
|---|---|
| 三個節點同時 15 個配置 | 37 秒，15/15，無重複 |
| `qm move_disk` 到 `local-lvm` 再搬回來 | 兩個方向都成功，guest 從搬回來的磁碟開機 |
| 對**執行中**的 guest 拍快照，然後倒回 | guest 開機後看到的是快照前的內容 |
| 擋掉 DSM 管理連接埠，guest 持續 I/O | 6.3 秒變 `inactive`，只警告**一次**，**guest 裡 0 個 I/O 錯誤**，解除封鎖後第一次輪詢就恢復 |
| `syno-min-free` 設得比 NAS 可用空間還高 | 配置被拒絕，並附上數字 |
| 要求 1 MiB | 建立出 1 GiB——文件寫的最小值，而 API 並不強制 |

### 備份、一台真的 guest、以及三個節點——關掉最後幾個空白的那一輪

在這之前的所有測試都是 `pvesm` 和 `dd`。這一次是一台 cirros guest 從 Synology LUN 開機，用三種方式備份、還原、跨三個節點遷移、再重新開機。三台節點都沒有 KVM，所以全程是 TCG 模擬。

| | |
|---|---|
| 匯入（`qm importdisk`，112 MiB）| 8 秒 |
| Guest 從 LUN 開機 | 掛上 `sda1`，**把檔案系統擴充到填滿整個 LUN**，進到登入提示 |
| `vzdump --mode snapshot`（線上）| 13 秒，36 MB 封存檔，QMP 備份啟動後就 `resuming VM again` |
| `vzdump --mode stop` | 19 秒，VM 正確地停止並重新啟動 |
| `vzdump --mode suspend` | 15 秒，1 秒後恢復 |
| `qmrestore` 到同一個 storage 上的新 VMID | 讀取 1 GiB，94.7% 是稀疏區 |
| 還原後的 guest 開機、payload `md5` | **與原始完全相同** |
| 即時遷移 pve1 → pve2 | 中斷 **5 毫秒** |
| 即時遷移 pve2 → pve3 | 中斷 **87 毫秒**，`/proc/uptime` 405 秒——兩次遷移全程連續 |
| Guest 重新開機 | payload 完好 |
| 三個節點、一個共用 storage | 三個都 `active`，三個都用複寫過來的憑證登入成功 |

`/etc/pve/priv/storage/` 會複寫：在 pve1 寫的檔案幾秒內出現在 pve2 和 pve3，權限是 `0600`。這是憑證那次修改最關鍵的假設，而在此之前一直沒有被檢查過。

#### 兩個缺陷，而第二個是同一段工作被寫了兩次

**`WwidState::orphans`沒有任何呼叫者**。它就是為下面這個情況寫的，註解寫得很長，而完全沒有地方呼叫它——一段代替修正存在的死程式碼。

情況是：一台 VM 即時遷移 pve1 → pve2 → pve3，然後在 pve3 上被銷毀，結果**pve1 和 pve2 各自留下一個 multipath map 和一筆追蹤記錄，對應一顆已經不存在的 LUN**。PVE 在遷移過程中唯一的 `deactivate_volumes` 呼叫位於 `sync_offline_local_volumes` 裡面，所以當時的推論是：對共用 storage 而言，來源節點永遠不會被通知。

##### 遷移不再留下 map

**2026-08-07 重新量測，沒有重現**。一台 VM 在 host-108 與 host-109 之間來回遷移，離線與線上、兩個方向都做。直接檢查 VM 離開的那個節點：**0 個 multipath map、0 個 by-path 裝置、追蹤檔是空的**——比原本那次量測預期的還乾淨。切換之後 VM 在來源節點停止時，`vm_stop_cleanup` 會呼叫 `deactivate_volumes`，所以來源節點「是」有被通知的。

原本那次量測早於下面描述的 `_detach_local` 修正：舊版停在第一次 flush，會留下一個正確的卸離不會留下的 map。

**沒有重新量測到的**是原本那個完整情境——一台 VM 遷走之後，在「更後面的」節點上被銷毀。既然遷走本身現在不留任何東西，就不該有 map 留下來變成死的；但那是推論，所以以推論的身分記在這裡，不是以結果的身分。

**而 `_detach_local` 清不掉它**。當 LUN 是從另一個節點被刪除的，這個節點的 iSCSI 工作階段還開著，所以每個 `sd` 節點會以死掉的裝置留下來，而 multipathd 會在它上面重建一個 map——`failed faulty running`，一條路徑，指向什麼都沒有。`free_image` 會先取得 slave 清單、flush、移除殘留路徑、再 flush 一次。`_detach_local` 停在第一次 flush。同一段程序被寫了兩次，而只有一份是對的；reaper 第一次真的執行時回報 **`flush incomplete`**，map 留在那裡。現在它會在——而且只在——flush 失敗時移除殘留路徑，所以一般的 VM 停止流程沒有改變。

兩者都修好之後，`pve-syno-reap --remove` 清掉了 pve1 和 pve2 上的死 map，而存活的 LUN、正在執行的 VM、以及該節點上 NetApp 的 map 都沒有被動到。

#### Proxmox VE 裡沒有任何東西呼叫 `deactivate_storage`

這是對整個 `/usr/share/perl5/PVE` 目錄樹驗證過的：只有 `Storage.pm` 裡的分派函式和各 plugin 自己的實作存在。`pvestatd` 和 API 都不會呼叫它。

所以這個專案自己那句「`pvesm set --disable 1` 會讓每個節點在下一次輪詢時停用」是**錯的**，而同一個下午寫下的一段程式碼註解聲稱 PVE 會「在這個節點用完這個 storage 時」呼叫它，也是錯的。相關專案 NetApp 那支早就發現並修正過完全相同的說法——這是一個沒有被匯入的家族教訓，不是新發現。各節點的清理屬於管理者的工作範圍，而 `pve-syno-reap` 就是那條路徑。

### 對這一段自己的修改做實機測試，又找出四個

憑證搬移、工作階段釋放、縮小拒絕、功能宣告修正，全都做過單元測試，而全都沒有對 NAS 跑過。開始跑的第一分鐘就找到一個會擋住發行的問題。

**在 0.5.3~beta1 和 0.5.4~beta1 上，`pvesm add` 根本無法運作。**

```
# pvesm add synologysan pvesyno --syno-password '...' ...
missing value for required option 'syno-password'
```

`extract_sensitive_params` 會在 `check_config` 驗證之前，就把每個機密屬性從參數裡移除——PVE 的順序就是這樣。所以當「必填選項」檢查執行時，它要找的那個密碼早就被拿走了。機密屬性必須宣告成 `optional => 1`，而由 plugin 自己檢查它有沒有被提供；PVE 自己的 CIFS plugin 就是這樣做的。任何單元測試都抓不到這個，因為問題出在 PVE 兩個階段之間的互動。

**CHAP 只在 target 被建立時才會套用**。實測：`pvesm set --syno-chap-username` 成功了，下一次啟用沒有拒絕任何事，而 NAS 上那個 target 仍然回報 `auth_type=0`。一個把 CHAP 加到已有 storage 上的管理者，既沒有得到錯誤，也沒有得到存取控制——這比它旁邊那個空密鑰的問題更糟，因為完全沒有任何可以察覺的跡象。現在 `ensure` 會拿陣列回報的狀態來對照 CHAP，而更新 hook 會把密鑰推送到這個 storage 擁有的**每一個** target，因為在 `per-volume` 模式下每顆磁碟各有一個。

**設定了 CHAP 帳號但沒有密鑰，原本會被接受、只是警告一下**。拒絕必須發生在狀態改變之前，所以現在會拒絕——而 `pvesm set` 完全不會動到設定。

**在更新 hook 裡拿 `$scfg` 來驗證是錯的**。PVE 會在 hook 回傳**之後**才套用 `$delete`，所以 `$scfg` 仍然帶著管理者正在移除的屬性，而憑證儲存區已經照著刪除做了。`pvesm set --delete syno-chap-username,syno-chap-password` 於是拒絕了自己。現在 hook 會算出「有效設定」——目前的設定，減去刪除，加上新值——也就是 PVE 接下來真的會寫進去的東西。

然後其他所有東西都重新完整驗證過：配置、啟用、區塊層級的倒回（8 MiB 隨機資料寫入後歸零再倒回，`sha256` 前後相同）、從快照複製、連續十二次失敗操作來壓 `DESTROY` 登出而沒有耗盡工作階段、釋放、停用、移除。**NAS 最後回到原本的四個 LUN 和三個 target，沒有任何 `pve-` 開頭的東西**，節點上也沒有 map、沒有工作階段、沒有 node 記錄、沒有 drop-in。

#### `multipath -w` 回報成功，而且什麼都沒做

這是在檢查唯一那個殘留物時發現的：`/etc/multipath/wwids` 會為每個曾經掛上的 LUN 留一行，而沒有任何東西會移除它。

| | 文件寫的 | 實測 |
|---|---|---|
| `multipath -w <wwid>` | 「從 WWIDs 檔案移除指定裝置的 WWID」| 在 multipathd 執行中的情況下，印出 `wwid '<...>' removed` 而**什麼都沒改**。檔案的 mtime 變了，內容沒變 |
| `multipathd del wwid <wwid>` | —| `fail` |
| `multipath -W` | 「把 WWIDs 檔案重設為只包含目前的 multipath 裝置」| **沒有執行，也永遠不會執行**。測試節點上那個檔案有 334 筆，其中 **319 筆是 NetApp 的** |

所以 plugin 刻意不移除它們，也不聲稱自己移除了。這是這個專案裡第三個「回報成功卻沒做事」的外部工具——在 DSM 的「拒絕卻建立了」以及 plugin 自己那個無聲的縮小之後。

這些殘留是無害的，而且理由是可以檢查的、不是靠期望：WWID 是從 LUN 的 uuid 推導出來的，所以一筆過期的項目只可能對應到它原本那顆 LUN，而那顆已經被刪掉了。它不是通往錯誤磁碟的路徑。

### 稽核的第三輪：一個修正弄壞了 CHAP，以及一個沒有人量過的斷言

這裡三個發現有兩個是關於**上一輪**的。這正是改完東西之後要再跑一次稽核的理由。

**搬移憑證弄壞了 CHAP，而且是無聲地、朝著最糟的方向壞**。把 `syno-chap-password` 設為機密屬性，代表 PVE 會把它從設定裡拿掉——所以 `$scfg->{'syno-chap-password'}` 變成 undef。而兩個 CHAP 呼叫點還在從那裡讀，兩個使用端最後都是 `$opt{chap_password} // ''`。所以結果不是失敗，而是一個**空的 CHAP 密鑰**，寫進 NAS 上的 target，也寫進節點的 iSCSI 記錄。一個自稱已經設定好、卻誰都放進來的存取控制。現在只有一個存取函式，而兩個使用端都不接受缺少的密鑰——共用密鑰沒有安全的預設值，所以兩邊都拒絕。

**`copy => { snap => 1 }` 是一個 plugin 兌現不了的承諾。**`qm clone --full --snapshot <name>` 會帶著快照名稱去問 PVE 的 `copy` 功能；回答「可以」就會讓它對 `path($scfg, $volname, $storeid, $snapname)` 執行 `qemu-img convert`，而那個呼叫會死掉——一個 Synology LUN 在快照上沒有裝置，除非先複製或倒回。RBD 可以說可以，因為它能直接定址 `pool/image@snap`。所以 PVE 會開始一個操作然後中途失敗，報出來的是定址的問題，而不是它被要求做的事。回答「不行」會讓它一開始就拒絕，並且給出可以動作的訊息，而那個動作——從快照做連結複本——是支援的。

`t/11-features.t` 現在會解析那張功能表，並斷言只有 `clone` 和 `snapshot` 對快照宣告為可用，所以任何新增的 `snap` 鍵都會強迫人回頭看那兩個讓宣告成立的拒絕。

**R-25 被記成已量測，而它從來不是**。快照時間戳那段註解說 `create_time` 已經「對 NAS 自己的時鐘確認過」。這份登記簿裡沒有任何這樣的量測。而它也無法用唯讀方式確定：**LUN 根本沒有 `create_time` 這個欄位**，所以必須真的拍一個快照再讀回來。

Proxmox VE 9 裡沒有任何東西會讀這個值——`Replication` 和 `QemuServer` 用的是快照**名稱**和一個 `parent` 欄位——所以單位錯了今天也不會壞掉任何事。它還是被加了防護：落在 2001–2065 之外的值會得到「沒有時間戳」，而不是一個標成 1970 的時間戳，而毫秒值會被換算。回報一個錯的時間戳比不回報更糟，因為它看起來像一個答案。

### 稽核的第二輪：又四個，以及憑證原本在哪裡

第一輪看的是邊界與防護。第二輪跟著資料走，而最糟的發現根本不在 plugin 的邏輯裡。

| 發現 | 後果 |
|---|---|
| **`syno-password` 被寫進 `/etc/pve/storage.cfg`** | 那個檔案是 `root:www-data 0640`，而一個 PVE 不知道是機密的屬性，會透過 `GET /storage/<id>` 回傳給任何持有 `Datastore.Audit` 的使用者。一個唯讀的稽核者就能讀到一組具備 SAN Manager 權限的 DSM 憑證。`syno-device-id`——一個常設的 2FA 旁路——也是同樣的存放方式 |
| **九個方法在錯誤路徑上洩漏 DSM 工作階段** | 二十個方法會建立 API 物件，九個在 `logout` 之前有 `die`。R-13 已確認第二次登入不會踢掉第一次，所以它們會累積：每失敗一次就一個 |
| **縮小是被無聲略過，而不是被拒絕** | 不管 plugin 回傳什麼，PVE 都會把**要求的**大小寫進 VM 設定，所以設定會宣稱一個 NAS 上並不存在的大小 |
| **「被拒絕後刪除」的清理什麼都沒證明** | 它會刪掉查詢找到的東西，而區隔它和一個原本就存在的 LUN 的，只有錯誤碼不是 18990538 |

憑證那一項最值得學，因為它**為什麼**是無聲的。當 plugin 什麼都沒宣告時，`PVE::Storage::Plugin::sensitive_properties` 會退回一份寫死的清單——`encryption-key keyring master-pubkey password`——而 `syno-password` 不在裡面。一個帶前置字串的屬性名稱會讓預設值失效，而且是朝著最不安全的方向失效，任何一層都不會警告。這是直接對 PVE 自己的機制驗證的，不是讀出來的：

```
PVE 對 synologysan 回報為機密的：syno-chap-password syno-device-id
                                 syno-otp syno-password
交給 hook 的 %sensitive：       syno-device-id, syno-password
寫進 storage.cfg 的：           syno-location, syno-portal, syno-username
```

它們現在放在 `/etc/pve/priv/storage/<storage>.syno`，權限 0600。**任何升級的人都必須把舊的值視為已經洩漏**——搬移一個 `www-data` 讀得到的機密，和保護它並不是同一件事。

### 這個形狀的第三個模組，以及一個成真的預測

`CLAUDE.md` 曾經寫過：如果出現第三個「是函式而不是方法」的模組，就給它同樣的防護。`Command` 就是那個模組，而防護並不存在。它在寫下第一個測試的那一刻就浮現了，因為 `$C->is_block_device($path)` 是最自然會寫出來的形式：

```
Odd number of elements in hash assignment at Command.pm line 50.
```

Perl 把類別名稱綁到了 `$path`，把剩下那個參數綁到 `%opts`。於是這個函式對一個確實存在的裝置回答**「不是區塊裝置」**——而稽核表上那條「`/dev` 路徑上的 `-b` 要經過 `is_block_device`」看起來仍然是滿足的。

這是這個家族目前為止這個錯誤最糟的形式。`Naming` 被位移的呼叫拒絕了它本該允許的東西；`Multipath` 的則是忽略了一個設定；而這一個**把一個安全問題答錯了，而且是安靜地、朝著採取動作的方向答錯。**

### R-10 縮小了：這台 NAS 上唯一存在的排程碰不到 LUN 的快照清單

唯讀，從 DSM 沒有封鎖的那個節點執行。問題是：使用者的**排程**快照會不會出現在 `list_snapshot` 裡，因而被某個 VM 操作刪掉或倒回過去。

| 問了什麼 | 答案 |
|---|---|
| `SYNO.Core.ISCSI.LUN.Snapshot.Schedule` | **錯誤 102——沒有這個 API**。在 DSM 7.1.1 上，LUN 快照排程不是一個獨立端點 |
| `SYNO.Core.TaskScheduler list` | 4 個作業，其中 2 個與快照相關且已啟用——兩個都是**共用資料夾**快照（`Share [photo] Snapshot`、`Share [homes] Snapshot`）|
| 對 NAS 上原有四個 LUN 各做一次 `list_snapshot` | **四個都是 0 個快照**，所以拿不到外來 `taken_by` 的樣本 |

共用資料夾快照和 LUN 快照是不同的物件，不可能出現在某個 LUN 的快照清單裡，所以在這台 NAS 上這個危險根本走不到。仍然沒有量到的是透過 Snapshot Replication 針對某個 LUN 建立的快照排程，那需要把該套件設定在這個 plugin 擁有的 LUN 上。

**它不會擋住任何事，因為那個過濾是白名單。**`snapshot_list` 只保留 `taken_by` 等於這個 plugin 自己標記的快照——所以來源不明的一律被排除，而不是需要先被認出來。黑名單會需要事先知道 DSM 能產生的每一種快照；白名單不需要。

### 這次稽核查出的兩件事

用機械方式掃過整個原始碼樹，而不是靠閱讀。檢查表大部分本來就是乾淨的——`decoded_content` 一律帶 `charset => 'none'`，沒有任何決定是靠比對訊息文字做的，沒有任何 `/dev` 路徑上的 `-b` 繞過那個有時限的輔助函式，沒有密碼進到 URL 裡，`LC_ALL=C` 釘在唯一執行命令的地方。有兩件不是：

- **成功路徑上一個沒有時限的 `waitpid`。**`sysfs_read_with_timeout` 先清掉自己的 alarm，然後用 `waitpid($pid, 0)` 回收子行程。要走到那一行必須先讀到 EOF，也就是子行程已經把資料寫出並且正要 `_exit`——所以就推論而言它是安全的。但「子行程到這時候一定已經結束了」正是這個模組存在要防止的每一次 hang 背後的推論，而一個只是被暫停、還沒死掉的子行程會讓它永遠卡住。現在它是有時限的回收，而且不送任何訊號：子行程已經把事情做完了。
- **所有權閘門只存在於 `free_image`。**`volume_snapshot_rollback` 會**覆寫整顆磁碟**，而它原本只靠 `taken_by` 白名單——這個推論是成立的，因為這個 plugin 拍的快照就代表它擁有那顆 LUN，但規則要的是一個檢查，不是一段推論。現在兩條快照路徑都直接呼叫 `is_pve_managed_volume($name, $storeid)`。

## 未驗證

這份清單裡沒有任何一項會被程式碼拿去行動。凡是 plugin 的決策依賴其中一項的，plugin 一律拒絕而不是假設。

### 需要在實機上寫入才能回答

| # | 問題 | 為什麼重要 |
|---|---|---|
| R-1 | ~~方法名稱、它的參數，以及倒回是否安全~~ **完整解答：`restore_snapshot(src_lun_uuid, snapshot_uuid)`**。LUN uuid 不變、比還原點更新的快照存活、`restored_time` 會記錄 | 所以倒回可以出貨，而且 `volume_rollback_is_possible` **不需要**相關專案那道拒絕。只送快照會被 18990508 拒絕 |
| R-2 | ~~`unmap_target` 是取代整份 target 清單還是加入~~ **已解答：`map_target` 是加入，`unmap_target` 只移除指定的那些**。仍然會送聯集，因為一版韌體上的一次測量不是承諾 | 若是取代，解除一個節點可能把全部一起解掉——Unity 就是那樣 |
| R-3 | ~~LUN 名稱長度上限與合法字元~~ **已解答**。200 可接受；`_`、空格、`+`、`@` 被拒絕；255 字元的名稱會「被拒絕但仍建立」| 見上方寫入測試各節。底線被拒絕這件事，改變了 storage id 折進名稱的方式 |
| R-4 | ~~容量對齊粒度~~ **已解答：每個容量都精確，完全不進位**。但文件寫的 1 GB 最小值**並未被 API 強制**，所以由 plugin 自己守 | 拿到比要求的小，代表檔案系統會寫滿然後失敗。在這裡風險反轉了：沒有任何東西阻止一顆荒謬的小 LUN |
| R-5 | ~~LUN 的 `vpd_unit_sn` 在 Linux 變成什麼 WWID~~ **已解答，並在兩個獨立樣本上確認。**`WWID = "3" + "6001405" + uuid 把 `-` 換成 `d` 後的前 25 字元`，並以掛載中的 LUN 用 `scsi_id` 驗證 | 決定節點怎麼認自己的裝置。仍然只當交叉核對：plugin 依據的是核心自己的答案 |
| R-6 | ~~有快照的 LUN 能否刪除、有複本的快照能否刪除~~ **已解答：兩者都不拒絕，已對應的 LUN 也不拒絕**。快照跟著它的 LUN 走，不會變成孤兒 | 不需要清依賴——但「刪除前先解除對應」完全變成 plugin 的責任 |
| R-7 | ~~複本是精簡的還是完整複製~~ **已解答：精簡。**`clone_snapshot` 給出 `allocated_size: 0` 的 `BLUN` | 連結複本與範本是真的便宜 |
| R-8 | ~~`is_action_locked` 會維持多久~~ **已解答**：1 GiB 建立後 1.2 秒、複製空 LUN 0.0 秒、**複製內含 512 MiB 的 LUN 3.5 秒**、任何大小的快照 0.20 秒。建立後立刻刪除仍然成功 | 大型複製會超過天真的等待——CSI 自己的上限只有 20 秒，而幾百 GiB 的複製可能超過 |
| R-9 | ~~`LUN list` 有沒有伺服器端上限~~ **部分解答：`offset`／`limit` 被忽略，也不回報總數**。所以清單會回傳它手上的全部——而回應裡沒有任何東西能證明這一點 | **被靜默截斷的清單讀起來就是「全部就這些」**，而讀它的程式碼決定什麼可以刪。沒有總數可對照時，只有第二次讀取才抓得到短少的答案 |
| R-10 | **部分解答**：每個快照都帶 `taken_by`，而本 plugin 自己的標記原封不動回來，所以過濾是可行的。DSM **排程**拍的快照會不會出現在 `list_snapshot`，還需要設一個排程才能問 | 若會，PVE 會把使用者的排程快照當成自己的，而且可能刪掉它們 |
| R-11 | ~~每個 target 的 `mapping_index` 上限，以及會不會重用~~ **已解答：會重用**。被釋放的編號會給下一顆被對應的 LUN | 這就是「寫到別人的磁碟」那種錯誤，而卸離一顆磁碟再掛上另一顆就到得了。這也是為什麼裝置身分來自核心的 WWID，絕不來自路徑。上限本身仍未測 |
| R-12 | ~~DSM 能不能承受並行請求~~ **已解答：十六個同時發出的建立全部成功**，而陣列的內容與 API 回報的一致。每個約 1 秒，看起來 DSM 內部是序列化的 | Cinder 把每一個請求都包在行程級的鎖裡；這裡沒有任何東西為了正確性需要它 |
| R-13 | ~~同一帳號第二次登入會不會擠掉第一次~~ **已解答：不會**。兩個工作階段同時有效 | 錯誤碼 107 讓共用一個帳號的叢集本來很值得擔心 |

### 需要一個非管理員帳號才能回答

| # | 問題 |
|---|---|
| R-14 | 最小 DSM 權限。探索當時用的是管理員帳號，所以只證明了「管理員可以」，沒有證明「非管理員不行」。見 `DSM-ACCOUNT_zh-TW.md` |

### 設計上已支援，但未驗證——需要本專案手上沒有的硬體

Synology 兩種高可用性架構都已實作。兩種都沒有實際跑過。plugin 對無法驗證的架構 **發出警告**而不是拒絕，並且在有人回報實際運行結果之前，不會聲稱它驗證過。

| # | 問題 |
|---|---|
| R-15 | **Synology HA（SHA）**：HA 叢集 IP 在故障切換後是否仍表現為單一管理位址；以及本 plugin 拿來當 storage 身分的 `SYNO.Core.ISCSI.Node` uuid，切換後會不會變。如果會變，把 storage 釘在它上面就不是保護而是破壞 |
| R-16 | **UC／SA 雙控制器機型**（`firmware_ver` 含 `DSM UC`）：兩個控制器各有自己的管理位址，沒有浮動位址。`SYNO.Core.Network.Interface` 接受 `relay_node=node0`／`node1` 列舉對側——在單控制器的測試機上兩者回傳相同的介面，所以這個機制在不需要它的地方是無害的。**依 Synology 自己 CSI 的邏輯實作，但未驗證**。未解的問題正是只有機箱能回答的：一顆 LUN 是否由單一控制器擁有、target 的 portal 是否依控制器而不同——這兩件合起來決定故障切換後節點還找不找得到自己的磁碟 |

---

## 測試計畫

### 階段 1——靜態，不需要 NAS

```bash
make release-check
```

語法、單元測試、與 CI 相同條件的整套測試、版本一致性、節點層級 multipath 守衛、以及「憑證不得出現在 URL」守衛。

### 階段 2——逆境與惡意輸入，不需要 NAS

從相關專案移植，因為那裡的每一個案例都是曾經進到release 的缺陷：

- 一個會接受連線但永不回應、中途斷開主體、用 HTML 回 200、不回應就關閉、登入成功但不回 sid 的伺服器。每一種情況都必須**快速**失敗、指名是哪個 storage、而且絕不卡住。
- 一個以 5xx 失敗的 create 只被送出**一次**。
- 惡意輸入：帶路徑穿越與 shell 特殊字元的 storage id、每個邊界上的容量對齊、十六路並行配置。
- 對每個解析器餵入缺少的、改名的、型別錯誤的欄位——每個欄位名稱都必須安全地失敗，而不是被拿去行動。

### 階段 3——對真實 DSM 唯讀

```bash
bin/pve-syno-api-probe --host <nas> --user <帳號>
```

不建立、不刪除任何東西，跑完會自己登出。對正式機是安全的。確認：API 範圍、有可用空間的 Btrfs 儲存空間、LUN 與 target 列表、`dev_attribs`，以及這台 DSM 是否開了防 CSRF。

以下這一項可選，而且**只在取得擁有者同意後**執行：

```bash
bin/pve-syno-api-probe --host <nas> --user <帳號> --probe-methods
```

它會探測哪些快照還原方法名稱存在，做法是指名一個 NAS 從未發出過的 LUN 與快照 uuid——所以存在的方法只能拒絕，而拒絕的錯誤碼證明它在那裡。之所以要明確開啟，是因為送出的畢竟是破壞性方法的名稱，即使它們能動到的東西並不存在。**R-1 就是這樣回答的。**

### 階段 4——寫入，在沒有人在意的儲存空間上

**前置條件**。一個專用的 DSM 儲存空間，或至少一個專用名稱前置字串；擁有者的明確同意；以及一份「絕對不可以碰」的 LUN 清單。每一步都可逆。

1. 建立一顆帶 `can_snapshot=1`、`emulate_tpu=1` 的精簡 LUN。讀回 `type`、`size`、`dev_attribs`——回答 R-3、R-4。
2. 建一顆刻意超長名稱的，和一顆奇數容量的。
3. 對應到一個 `max_sessions=0` 的 target；從一個節點登入；讀 `/dev/disk/by-id`、`/sys/block/sdX/device/wwid`——**回答 R-5**。
4. 把第二、第三顆 LUN 對應到同一個 target；解除中間那顆；再對應第四顆——回答 R-2 與 R-11。
5. 拍快照、列出、從快照複製、讀 `allocated_size`——R-7、R-10。
6. 試著刪除一顆有快照的 LUN；試著刪除一個有複本的快照——R-6。
7. 擴充容量；全程觀察 `is_action_locked`——R-8。
8. 從一個節點十六路並行建立，再從兩個節點——R-12。
9. 刪掉所有建立的東西，確認 NAS 回到原本的樣子。

### 階段 5——叢集

- 兩個節點同時登入同一個共用 target。
- 同一個帳號上兩個節點的工作階段同時存活——**R-13**。
- 一台磁碟在此 storage 上的 VM 在節點之間遷移。
- 其中一個節點正在做複製時，量測每個節點 `pvesm status` 的時間。

### 階段 5b——只有一台 NAS 要怎麼測 multipath

**Synology 的 multipath 和雙控制器無關**。單控制器機型是靠**多個網路 portal** 提供多重路徑的，而一台有兩張網路卡的 NAS 就足以做出真正的雙路徑 map。

測試機上從 `SYNO.Core.Network.Interface` 讀到的：

| 介面 | 位址 | 速度 | 狀態 |
|---|---|---|---|
| `ovs_eth0` | 192.0.2.10（靜態）| 1000 | connected |
| `ovs_eth1` | 192.0.2.11（**DHCP**）| 1000 | connected |

這已經是兩條可用的路徑了。但有三件事必須先弄對：

1. **target 的 `max_sessions` 要設成 0**。預設是 1，而一個工作階段就是一條路徑——所以停在預設值的 target 根本做不出 multipath，更不用說讓多節點共用。
2. **第二張介面要給靜態位址**。走 DHCP 的資料 portal 位址會變，而位址會變的路徑就是會消失的路徑。給它靜態位址，或在 DHCP 上做永久保留。
3. **這裡兩個位址在同一個子網路，而這是最麻煩的一點**。Linux 會很自然地把兩個工作階段都從路由表偏好的那張介面送出去，於是你得到的是「兩個工作階段走同一條物理線路」，一個看起來有備援但其實沒有的 map。要明確把每個工作階段綁到各自的介面上：

   ```bash
   iscsiadm -m iface -I path0 --op=new
   iscsiadm -m iface -I path0 --op=update -n iface.net_ifacename -v <網路卡0>
   iscsiadm -m iface -I path1 --op=new
   iscsiadm -m iface -I path1 --op=update -n iface.net_ifacename -v <網路卡1>

   iscsiadm -m discovery -t st -p 192.0.2.10 -I path0
   iscsiadm -m discovery -t st -p 192.0.2.11 -I path1
   iscsiadm -m node -T <target-iqn> -I path0 --login
   iscsiadm -m node -T <target-iqn> -I path1 --login

   multipath -ll        # 應該看到一個 map、兩條路徑，都是 active ready running
   ```

   分成兩個子網路或兩個 VLAN 是更乾淨的做法，交換器允許的話值得這樣做。DSM 也可以在同一個物理連接埠上建 VLAN 子介面，那會在一條線上產生兩個 portal 位址——足以把每一條程式路徑都跑過，但顯然不是真正的備援。

**不動 NAS 就能測故障切換**。從節點端把其中一個 portal 擋掉，然後觀察 map，不要拔線也不要去停用 NAS 的介面：

```bash
nft add table inet mptest
nft add chain inet mptest out '{ type filter hook output priority 0; }'
nft add rule inet mptest out ip daddr 192.0.2.11 tcp dport 3260 drop

multipath -ll        # 那條路徑必須變成 failed，而 I/O 必須繼續
nft delete table inet mptest      # 然後它必須恢復
```

要確認的是：全程 I/O 沒有中斷；規則移除後 map 會恢復；`no_path_retry` 是一個數字，所以**所有**路徑都斷掉時是失敗而不是無限排隊；以及 plugin 在中斷期間所做的任何事都沒有動到其他 storage 的 map。

**如果第二條路徑真的做不到**——單網路卡機型——那就直說，不要假裝。單路徑的 map 仍然會跑到 map 建立、WWID 釘定、擴充與 flush，但故障切換的路徑就是沒有測過，而這件事應該寫在這份文件裡，不是寫在發行說明裡。

### 階段 6——故障注入

- 一個指向不可路由位址的 storage：其他 storage 保持 `active`，`pvesm status` 只增加大約一個逾時的時間，不能更多。
- 操作進行中拔掉 NAS 的管理介面。
- 刻意設錯密碼：**只嘗試登入一次**，storage 回報需要人介入。自動封鎖不可以被觸發。
- 把 DSM 儲存空間填到剩餘不足 1 GB：配置被拒絕，訊息說得出原因。
- 停掉 multipathd；寫入過程中拔掉一條路徑。

### 階段 7——在節點上實地測試

安裝建置好的套件，並比對安裝前後的 `pvesm status`。除此之外不可以有任何狀態改變。確認節點上其他 storage 未受影響——這個 plugin 是在一台同時跑 NetApp 與 Pure Storage plugin 的節點上開發的——並確認沒有動到任何其他廠商的 multipath map。

---

## 每次發行前——操作清單

**從網頁介面驅動**。這不是偏好：`pvedaemon`、`pveproxy`、`vzdump` 與 `pct` 是以 `#!/usr/bin/perl -T` 執行而且**完全沒有 `PATH`**，而 `qm`、`pvesm`、`pvesh`、`qmrestore` 不是。已經有五個缺陷藏在「從 `qm` 跑完全正常、從操作者真正使用的介面跑就壞掉」的程式碼裡，而且有兩輪實機驗證通過、網頁介面卻照樣失敗。**從 shell 跑一輪是回歸測試，不是驗證。**

| | 操作 | 走到什麼 |
|---|---|---|
| **A1–A4** | 新增 · 編輯 · 設定 CHAP · 移除 storage | `on_add_hook`、`on_update_hook_full`、`on_delete_hook`，以及 `/etc/pve/priv` 裡的憑證存放。**GUI 到不了**——PVE 把儲存類型清單寫死了，所以這個階段是 `pvesm` 加上在節點上跑一次 `perl -T` |
| **B1** | 新增磁碟 | `alloc_image`，而第一顆會建立 target |
| **B2** | 擴充 | `LUN::resize`，然後 `grow_map`——map 必須真的到達新容量，不是只有 NAS 到 |
| **B3** | 移動到別的 storage 再移回 | `volume_export` / `volume_import` |
| **B4** | 卸離並移除 | `free_image`：解除對應、刪除 LUN、清掉 map、解除追蹤 |
| **C1 · C2** | 快照，執行中與關機 | `volume_snapshot`、主機快取清空、DSM 描述 |
| **C3** | **倒回** | `restore_snapshot`、快取清空**與**失效，以及工作階段重新掃描——DSM 在還原期間會要求 initiator 登出 |
| **C4** | 刪除快照 | 所有權閘門 |
| **C5** | 在 SAN Manager 裡讀到名稱 | PVE 的快照名稱有進到描述欄 |
| **D1** | 關機與啟動 | `activate_volume`：iSCSI 登入、工作階段重新掃描、WWID 確認、建立 map、追蹤 |
| **D2** | 遷移離開再遷回，離線與線上 | 來源節點被留在乾淨的狀態 |
| **D3 · D4** | 完整複製 · 從快照複製 | `clone_image`；D4 需要 `--full 0` 而且要用指令列 |
| **D5** | 轉範本，再從它做連結與完整複製 | `create_base` 與兩條複製路徑 |
| **E1 · E2 · E3** | `vzdump` 三種模式的備份 | `-T` 底下的讀取路徑 |
| **E4 · E5** | 還原到新的 VM ID · 覆蓋原本的 | `alloc_image` 與 `free_image` 連在一起 |

**然後盤點兩邊**。這一步才是抓「操作回報成功但其實沒做到」的地方：

```bash
# 節點端 —— 每一個 map、每一筆追蹤紀錄都必須對得上一個活著的磁碟
multipath -ll | grep -cE '^[0-9a-f]{20,}'
grep -v '^#' /var/lib/jt-pve-storage-synology/*.wwids
pve-syno-reap --all                 # 乾跑；必須回報沒有殘留

# NAS 端 —— 每一顆 LUN、每一筆 target 對應都必須對得上一個 VM 設定
bin/pve-syno-api-probe --host <nas> --user <帳號>
```

NAS 上有一顆沒有任何設定引用的 LUN，或一筆指向已不存在 uuid 的 target 對應，就是一個靜默成功的外漏。`flush_map` 從來沒有真的移除過任何 map 這件事，就是這樣被抓到的。

## 回報

如果你在自己的 NAS 上跑過上面任何一項，結果比這份文件裡的任何內容都有價值——尤其是型號或 DSM 版本和上面不同的時候，尤其是 R-1。請附上型號、DSM 版本、儲存空間的檔案系統，以及 NAS 的回應。

---

## 給想深入的人

以下沒有任何一項是安裝或使用這個 plugin 所必需的。它們寫在這裡，是因為每一項都是付出代價才確立的，而撞到其中任何一項的讀者，應該能查到原因而不是靠猜。

### 為什麼每個節點都要裝，以及版本混雜的叢集為什麼難懂

一個 storage 操作是在**擁有那個 guest 的節點**上執行的，用的是**那個節點上的** plugin——不是提供網頁介面的那一台。所以版本混雜的叢集，行為會隨著 VM 剛好在哪裡而不同，而症狀很難懂：你明明裝好的修正，對某些 guest 就是不存在。

真實遇過：在一個還跑著舊版的節點上拍的快照，帶的是舊的 DSM 描述，而瀏覽器所連的那台已經升級了。那兩次 `apt` 甚至可以從「Reading database …N files」的數字分辨出來。

**沒有裝** plugin 的節點比裝了舊版更糟，因為它是靜默失敗的：`pvesm add` 寫的是叢集設定，所以在一個節點上執行就足以建立這個 storage——但 `pveproxy` 在啟動時就把 plugin 清單載入了，而不認得 `synologysan` 這個類型的節點會**把這個 storage 從清單裡略過**，而不是回報錯誤。在有裝的節點上這個 storage 是存在而且可用的。這個症狀看起來就像 `pvesm add` 失敗了，但它並沒有。

### 為什麼不需要重啟服務

這個套件會安裝到 `/usr/share/perl5/PVE` 底下，而 `pve-manager` 用一個 `interest-noawait` trigger 監看那個路徑——就是輸出裡「Processing triggers for pve-manager」那一行。它的 postinst 會對 `pvedaemon`、`pvestatd`、`pveproxy`、`spiceproxy`、`pvescheduler` 執行 `reload-or-try-restart`。

reload 就夠了，因為 `pvedaemon` 的 `ExecReload` 就是 `pvedaemon restart`，而它對自己做的是 `exec(2)`——換掉整個執行中的程式，但保留 PID：

```
pvedaemon[1333139]: received signal HUP
pvedaemon[1333139]: server shutdown (restart)
systemd[1]: Reloaded pvedaemon.service - PVE API Daemon.
pvedaemon[1333139]: restarting server
pvedaemon[1333139]: starting 3 worker(s)
```

全程都是同一個 PID，所以這對**升級**和第一次安裝一樣成立：主行程重新 exec，然後 fork 出全新的 worker，從磁碟讀取新的模組。已經在處理請求的舊 worker 會用舊的程式碼跑完——上面那次大約五秒——所以升級當下已經開始的操作，可能會在你剛換掉的那一版上完成。如果你的環境有什麼東西擋住 `deb-systemd-invoke`，備援做法是 `systemctl restart pvedaemon pveproxy pvestatd`。

### 如果你已經用 `dpkg -i` 失敗過

`open-iscsi` 與 `multipath-tools` 是一台 Proxmox VE 節點真的可能缺少的兩個套件——PVE 裡沒有任何東西會把它們帶進來，而安裝 `multipath-tools` 才是那個維護時段真正要做的事。這個套件另外需要的四個 Perl 模組，各自是 86 到 151 個 PVE 套件的相依項，所以它們本來就在。

那也是為什麼安裝那一行是 `apt install ./…` 而不是 `dpkg -i`：`dpkg` 不會處理相依性，所以在沒有 `multipath-tools` 的節點上，它會解開套件然後以「dependency problems —leaving unconfigured」失敗。前面的 `./` 是必要的，否則 apt 會把它當成套件名稱。

文件先前的版本寫的是 `dpkg -i`。那會讓套件解開但「未設定」，而 apt 接著就拒絕求解任何其他東西——你會看到 `Unmet dependencies`，說 `kpartx` 和 `sg3-utils-udev`「not going to be installed」，看起來像套件庫的問題，但不是。先清掉它：

```bash
dpkg --remove jt-pve-storage-synology
```

然後再跑安裝那一段。如果清掉之後前置套件還是裝不起來，那才真的是套件庫問題——用 `apt policy kpartx sg3-utils-udev` 檢查：`kpartx` 來自 Debian 的 `trixie/main`，而 `sg3-utils-udev` 來自 Proxmox VE 的套件庫。

`cd /tmp` 也不是多餘的：apt 的 `_apt` 使用者讀不到 `/root`，所以下載到那裡會讓 apt 退回以 root 身分非沙箱執行，並印出一行「Download is performed unsandboxed as root」。無害，但對一份要被原樣複製的文件來說是雜訊。

### 倒回這個方法是怎麼找到的

兩份參考實作都沒有快照倒回：Kubernetes 與 Cinder 都是用「把快照複製成一個**新的** volume」來還原，所以兩者都不需要，而 Synology 完全沒有記載。這個方法是靠對一台 DSM 詢問**九個候選名稱**找到的，其中一個回答了——`restore_snapshot`，收 `src_lun_uuid` 與 `snapshot_uuid`。

但找到名稱還不足以把它打開，因為有三件事必須成立，而事先沒有一件是可知的：

| | |
|---|---|
| LUN 的 uuid 不可以變 | **它不會變**。所以 SCSI 序號與 WWID 都存活 |
| 比還原點更新的快照必須存活 | **會存活**。還原到三個之中最舊的那一個，三個都還在 |
| 事後必須看得出來 | `restored_time` 會記錄還原當下的 epoch 秒 |

第二件正是相關專案**拒絕**越過較新快照倒回的原因：在那些陣列上較新的快照會被銷毀。這裡什麼都不會被銷毀，所以那道限制不需要，一顆磁碟也可以反覆倒回。

探索工具裡的 `--probe-methods` 就是為了讓這種問題可以在不猜的情況下被回答。它送的是一組 NAS 從來沒有發出過的 LUN 與快照 uuid，所以一個存在的方法只可能拒絕——而拒絕的代碼就證明它在那裡。DSM 對不存在的方法回 **103**。

### 為什麼從快照複製需要用指令列

網頁介面不會讓你做，而錯誤訊息是 `Full clone feature is not supported for a snapshot of ...`。

GUI 對任何「不是範本」的東西一律寫死用**完整複製**——`pvemanagerlib.js` 裡的 `isTemplate ? 'clone' : 'copy'`——而「完整」複製的意思是 Proxmox VE 自己用 `qemu-img convert` 去讀來源，而且是定址到**快照當下的那顆磁碟**。Synology 的 LUN 在快照上沒有裝置，所以 plugin 宣告不支援，PVE 就在動手之前拒絕。宣告支援反而更糟：PVE 會開始做、做到一半失敗，而訊息講的是路徑，不是你要求的那件事。

**連結**複製從快照是可行的，而且**必須加 `--full 0`**——省略 `--full` 不等於同一件事，因為 PVE 對任何「不是範本」的東西把它預設為「真」：

```bash
qm clone 146 149 --name from-snapshot --snapname mysnapshot --full 0
```

在這個陣列上「連結」這個字說得太保守：DSM 的 `clone_from_snapshot` 做的是 **reflink**，所以新的 LUN 是獨立的——之後刪掉來源快照也不影響它——而建立當下不佔空間。已量測：在複本**執行中**把範本的 LUN 刪除，複本照樣跑。

---

## 協定實際上長什麼樣

Synology 沒有公開 SAN Manager Web API 的規格，所以下面每一行都是這個專案必須自己確立、然後保存下來的東西。它們放在這裡而不是文件網站上，是因為沒有任何一項是安裝或使用這個 plugin 所必需的——但每一項都改變了一個設計決定，而好奇「程式碼為什麼要這樣做」的讀者，應該找得到答案。

### 改變了設計的發現

| 發現 | 後果 |
|---|---|
| 工作階段必須以 Cookie: id=<sid> 標頭攜帶，而 DSM 自己從不設定這個 cookie | 用戶端必須自己從登入回應組出來。只用表單參數會得到 119 |
| 開啟防 CSRF 後，少了 token 會回 105 權限不足 | 一個看起來完全像權限問題、但根本不是的錯誤碼 |
| 自動封鎖：5 分鐘 3 次失敗，該 IP 被封鎖一天 | 密碼設錯時，正常輪詢約 30 秒就會讓一個節點被鎖 24 小時。所以憑證被拒絕時第一次就停 |
| can_snapshot 與 emulate_tpu 預設都是 0 | 沒有明確要求就建立的 LUN 拍不出快照，也永遠不會把釋放的空間還回去 |
| vpd_unit_sn 就是 LUN 的 uuid，而 WWID 由它確定性地衍生 | 節點可以靠核心自己的認定辨識裝置，而不是靠它從哪個路徑被發現。兩份參考實作都只用 by-path |
| 回報失敗的建立仍可能把 LUN 建出來（255 字元名稱，錯誤 18990068）| 所以失敗的建立絕不被相信：事後按名稱查一次，找到的就接管或刪掉。否則每次這種失敗都漏掉一顆 PVE 沒有紀錄的 LUN |
| mapping_index 會重用——被釋放的編號會給下一顆被對應的 LUN | 殘留的裝置路徑會指向另一顆磁碟。兩份公開用戶端都只用路徑認裝置；在這個陣列上那不安全，這也讓 WWID 推導成為承重結構 |
| CSI driver 的十二種型態 LUN 過濾條件藏了一顆 LUN——一個 Virtual Machine Manager 的虛擬磁碟 | 它的容量還是吃同一個儲存空間。所以本專案不帶過濾地列出、在本地比對：一個已被驗證為不完整的過濾條件，比不過濾更糟 |
| max_sessions 預設是 1 | 停在預設值的 target 只容許一個節點，所以叢集無法共用，也做不出 multipath |

### 一條讀核心原始碼會讀錯的規則

Synology LUN 的 WWID 是由它的 uuid 組成的：

```
WWID = "3" + "6001405" + (uuid 把 "-" 換成 "d"，取前 25 個字元)
```

`6001405` 是 Linux-IO 的 IEEE 公司識別碼，所以 target 是 LIO 系的——**而這正是陷阱**。上游 LIO 用 `hex_to_bin()` 轉換序號，它會**跳過**每一個非十六進位字元；照著核心原始碼讀的人，因此會預期那些連字號被丟掉。在 DSM 上它們是**被換成 `d`**，不是被丟掉，而這是拿兩顆 LUN 對照核心自己的 `scsi_id` 輸出確立的，不是靠讀原始碼。

uuid 的最後 11 個字元被丟掉了，所以 WWID 無法反推回 uuid。算出來的值是交叉核對用的；最終認定一律取決於核心自己對那個裝置的回報。
