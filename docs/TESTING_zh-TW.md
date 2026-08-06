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

**已經做過的事：**唯讀探索、在專用名稱前置字串下的寫入測試，以及一次把 LUN 掛到 Proxmox VE 節點——下面的 WWID 推導與 multipath 行為就是從那裡來的。模組層（`Synology::API`、`::LUN`、`::Target`、`::Naming`、`::Multipath`、`::Command`、`::ISCSI`）已對這台硬體完整跑過。**PVE plugin 本身還沒有寫**，所以這裡沒有任何東西是透過 `pvesm` 驗證的。

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

- **`vpd_unit_sn` 就是 LUN 的 uuid，一字不差。**那是 SCSI VPD 的單元序號，也就是 Linux WWID 的來源。這代表 LUN 與裝置之間可以靠**核心自己的認定**對應，而不是只靠它被發現的路徑。兩份參考實作都只用 `/dev/disk/by-path`。
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

`6001405` 是 Linux-IO 的 IEEE 公司識別碼，所以 Synology 的 target 是 LIO 系的——**但這不是原廠 LIO 的行為。**上游的 `spc_gen_naa_6h_vendor_specific()` 用 `hex_to_bin()` 轉換序號，非十六進位字元會被**跳過**，那樣算出來是 `36001405a1b2c3d45e6f4a7b8c9d0e1f2`——而那不是 NAS 產出的值。Synology 是把連字號映射成 `d`，不是丟掉。**照著上游原始碼推論會得到一個很有自信的錯誤答案**，只有實機給了對的。

三個後果：

1. WWID **可以在裝置出現之前就算出來**，所以 multipath map 能確定性地釘住，而且節點能判斷「我找到的裝置是不是我要的那顆 LUN」——不必只相信它是從哪個路徑被發現的。
2. **uuid 的最後 11 個字元被丟掉了。**所以 WWID 不是 uuid 的無損函式、不可反推，而且兩個只在尾端不同的 uuid 會撞同一個 WWID。隨機 uuid 下機率可忽略，但規則不變：算出來的值是**交叉核對**用的，最終認定要由核心自己的識別決定。
3. multipath `conf.d` drop-in 需要的兩個字串是 `vendor "SYNOLOGY"` 與 `product "Storage"`。**兩個都不可能從 NAS 的 API 取得**——它們是 SCSI INQUIRY 的回應。猜錯會讓 drop-in 靜靜地不生效，而 `no_path_retry` 不生效就代表所有路徑消失時會無限排隊。

**一個樣本不足以證明一條規則。**上面的規則精確重現了一個實測到的 WWID，這足以拿來當交叉核對，但不足以拿來依賴。另外兩顆 LUN 的預測值記錄在非公開的文件裡，等第一次掛上測試 LUN 時對照——如果規則是錯的，這一節會改，而 plugin 不論如何都會從核心讀回 WWID。

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

**所以本專案從不送型態過濾條件。**它不帶過濾地列出，然後在本地用名稱比對——而名稱本來就是它唯一信任的所有權判準。探索工具現在會跑兩次列表並回報過濾條件藏了什麼，因為下一台 DSM 可能藏的是別的型態。

這是那條通則的具體版本：**一個 plugin 要求過濾過的清單，必須被檢查它真的過濾了什麼**，而「本來就沒有」和「被過濾掉了」在回應裡是分不出來的。

### 建立回報失敗，卻還是把 LUN 建出來了

可穩定重現。名稱剛好 **255 個字元**的 LUN 會被錯誤碼 **18990068** 拒絕——而 LUN 還是被建立了：完整名稱、正確容量、`status: normal`，完全可用。到 256 個字元時拒絕是乾淨的（**18990503**，名稱不合法），什麼都不會建。

```
建立，255 字元名稱  ->  REFUSED 18990068
                    ->  ……而且陣列上多了 1 顆 LUN
建立，256 字元名稱  ->  REFUSED 18990503，什麼都沒建
```

**所以一個失敗的建立絕對不能單憑它自己的回答就相信。**任何建立失敗之後，plugin 都要按名稱查一次，然後決定接管它或刪掉它。少了這一步，每一次這種失敗都會漏掉一顆 Proxmox VE 完全沒有紀錄的 LUN：空間沒了、沒有任何東西指向它，而下一次嘗試又會再建一顆。

這也是為什麼名稱長度限制要在**送出請求之前**就檢查，而不是交給 NAS 去拒絕。

### 倒回在這裡是安全的，而那不是理所當然

`restore_snapshot` 收 **`src_lun_uuid` 與 `snapshot_uuid`**。只送快照會被 **18990508** 拒絕，所以 LUN 也必須指名。

量了三件事，而且這三件事全都必須是這個答案，倒回才可能出貨：

| 問題 | 答案 |
|---|---|
| LUN 的 uuid 會變嗎？| **不會。**所以 SCSI 序號與 WWID 不變，節點不會突然看到另一顆磁碟 |
| 比還原點更新的快照會活著嗎？| **會。**還原到三個之中最舊的那一個，三個都還在 |
| 有被記錄嗎？| `restored_time` 從 0 變成還原當下的 epoch 秒 |

第二個答案值得停下來看，因為相關專案必須**拒絕**越過較新快照的倒回——在那些陣列上較新的快照會被銷毀，而讓 PVE 默默做那件事的 plugin，等於刪掉使用者還看得到的快照。這裡什麼都不會被銷毀，所以 `volume_rollback_is_possible` 不需要那道限制，一個 storage 也可以反覆倒回。

### 快照與複本之間沒有依賴鏈

這個家族裡其他每一個陣列，都會拒絕刪除「有別的東西依賴它」的物件，而那兩種拒絕都造成過真實的缺陷。Synology 兩種都不拒絕：

| 嘗試 | 結果 |
|---|---|
| 刪除有快照的 LUN | **允許。**快照跟著走——對已刪除的 uuid 呼叫 `list_snapshot` 回 18990531，所以不會留下孤兒 |
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

**被釋放的編號會交給下一顆 LUN。**一個還握著 `...-iscsi-<iqn>-lun-2` 舊裝置的節點，會發現那個路徑現在指向一顆完全不同的 LUN。這屬於「寫到別人的磁碟」那一類錯誤，而且用一般操作就到得了：卸離一顆磁碟、掛上另一顆。

兩份公開的參考實作都只用 `/dev/disk/by-path` 認裝置。**在這個陣列上那不安全。**這就是為什麼上面那條 WWID 推導是承重的，不是方便而已：一個裝置只有在**核心自己的識別**與被要求的那顆 LUN 相符時才會被接受。

### 對應是「加入」，解除對應只動指定的那些

| 呼叫 | 行為 |
|---|---|
| 對一顆已對應到別處的 LUN 送 `map_target` 一個 target | **加入。**既有的對應仍然存在 |
| `unmap_target` 一個 target | **只**移除那一個 |

這和 Unity 的 `hostAccess` 正好相反——那邊清單是被取代的，送一個 host 就會把叢集裡其他每個節點解除對應。這裡的逐節點對應照原樣寫就是安全的。plugin 仍然會讀出現有清單並送出聯集，因為一個在一版韌體上量過一次的行為不是承諾。

### 並行與工作階段

- **十六個同時發出的建立全部成功**，耗時 15 秒，而陣列的內容與 API 回報的一致——沒有遺失也沒有重複的 LUN。每個建立約 1 秒，看起來 DSM 內部是序列化的，這也解釋了 Cinder 為什麼把每個請求都包在行程級鎖裡；但這裡沒有任何東西為了正確性需要那個鎖。
- **同一帳號的第二次登入不會擠掉第一次。**兩個 sid 同時有效，所以共用一個帳號的叢集節點不會互相踢掉對方——而錯誤碼 107「被重複登入中斷」本來讓這件事很值得擔心。

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

**不能假設 `/dev/mapper/<wwid>` 存在。**測試節點設了 `user_friendly_names yes`，所以 multipath 把 map 命名為 `mpathc`。相關專案的 `path()` 回傳 `/dev/mapper/<wwid>`，而在這裡那個路徑根本不存在。**一直都存在**的是 dm-uuid 連結：

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

**空間是延遲回收的。**刪除一顆寫入過 512 MiB 的 LUN 之後，過了幾分鐘儲存空間的可用容量仍然沒有變。什麼都沒有遺失——Btrfs 會用它自己的步調還回來——但一個預期「刪除後可用空間立刻上升」的 plugin 會下錯結論，而 `syno-min-free` 這道守衛也不能被它嚇到。

### R-14：非管理員帳號連登入都過不了

一個剛建立的非管理員帳號在**登入本身**就被 **402** 拒絕，還沒機會嘗試任何 SAN API——所以這次執行無法區分「碰不到 SAN API」與「根本登不進 DSM」。要再往下釘，需要在介面上手動授予 DSM 應用程式權限，而每試一次就是一次登入嘗試，對著一個**「5 分鐘 3 次失敗封鎖 1 天」**的自動封鎖政策——所以刻意就此停手。`DSM-ACCOUNT_zh-TW.md` 的實務建議不變：帳號必須是管理員，而其他一切都應該從它身上拿掉。

那次嘗試順帶得到兩個值得留下的發現：

- 對 `SYNO.Core.User` `create` 傳 `expired=now`，會產生一個存在但無法登入的帳號。症狀是一個看起來像權限問題的 402——一個被猜出來的參數，默默建立了一個壞掉的帳號。
- `SYNO.Core.User` `set` 帶 `expired=never` **回報成功、卻什麼都沒改。**又一個不能照字面相信的 API 回應。

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

`on_delete_hook` 只在**一個**節點上執行——就是打 `pvesm remove` 的那個。它會移除 target 並釋放那個節點的工作階段。其他節點永遠不會被通知，因為 storage 一旦從設定裡消失，PVE 就沒有理由在那裡為它呼叫 `deactivate_storage`。

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

### 名稱規則

| | |
|---|---|
| 長度 | 200 字元完全接受。255 會「被拒絕但仍建立」，256 以上乾淨拒絕。200 到 255 之間的確切上限沒有再往下釘，因為這裡沒有任何東西需要那麼長的名稱 |
| 合法 | `-` 連字號、`.` 點、`:` 冒號、大寫、數字 |
| **被拒絕**（18990503）| **`_` 底線**、空格、`+`、`@` |

**底線這件事很重要。**Proxmox VE 的 storage id 可以含底線，而相關專案會把 storage id 折進陣列物件的名稱裡——所以在這裡折疊不能用 `_`，含底線的 storage id 必須被轉成合法字元。而那會把相關專案踩過的撞名問題帶回來：兩個不同的 storage id 折成同一個前置字串，然後彼此都看得到、也刪得掉對方的磁碟。所以「拒絕第二個這樣的 storage」那道檢查，在這個陣列上不是可選的。

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

這改變了建立 LUN 的方式：`can_snapshot=1` 與 `emulate_tpu=1` 必須明確送出，否則得到的是一顆拍不出快照、而且永遠不會把釋放的空間還回去的 LUN。**CSI 的 `dev_attribs` 完全由呼叫端給、自己一個預設都沒有；Cinder 一個都不送。**兩份都不可能告訴我們這件事——是實機告訴我們的。

### Target

`max_sessions` **預設是 1**，而停在 1 的 target 只容許一個節點登入。任何要讓 PVE 叢集共用的 target 都必須設成 0。

Target 的 IQN 裡嵌的是**建立當時**的 NAS 主機名稱——測試機上有帶著兩個不同主機名稱的 target，因為它改過名。所以絕對不可以用「現在的主機名稱」去推導 IQN，再拿去和既有的 target 比對。

### API 範圍

公佈 1184 個 API。SAN 相關全部在 `entry.cgi`、全部 `requestFormat=JSON`（**每個參數都必須 JSON 編碼**）、全部只有 v1：`SYNO.Core.ISCSI.{LUN,Target,Node,Host,FCTarget,Lunbkp,Replication,VMware}`、`SYNO.Core.Storage.{Volume,Pool,iSCSILUN}`。`SYNO.API.Auth` 是 v1-7。

`SYNO.Core.ISCSI.Host`——IQN 存取控制物件——**存在且會回應**（`{"hosts":[]}`）。兩份參考實作都不知道它在那裡。

這個型號上沒有 `SYNO.San.Nvme.*`，所以它不支援 NVMe-oF。

---

## 未驗證

這份清單裡沒有任何一項會被程式碼拿去行動。凡是 plugin 的決策依賴其中一項的，plugin 一律拒絕而不是假設。

### 需要在實機上寫入才能回答

| # | 問題 | 為什麼重要 |
|---|---|---|
| R-1 | ~~方法名稱、它的參數，以及倒回是否安全~~ **完整解答：`restore_snapshot(src_lun_uuid, snapshot_uuid)`。**LUN uuid 不變、比還原點更新的快照存活、`restored_time` 會記錄 | 所以倒回可以出貨，而且 `volume_rollback_is_possible` **不需要**相關專案那道拒絕。只送快照會被 18990508 拒絕 |
| R-2 | ~~`unmap_target` 是取代整份 target 清單還是加入~~ **已解答：`map_target` 是加入，`unmap_target` 只移除指定的那些。**仍然會送聯集，因為一版韌體上的一次測量不是承諾 | 若是取代，解除一個節點可能把全部一起解掉——Unity 就是那樣 |
| R-3 | ~~LUN 名稱長度上限與合法字元~~ **已解答。**200 可接受；`_`、空格、`+`、`@` 被拒絕；255 字元的名稱會「被拒絕但仍建立」| 見上方寫入測試各節。底線被拒絕這件事，改變了 storage id 折進名稱的方式 |
| R-4 | ~~容量對齊粒度~~ **已解答：每個容量都精確，完全不進位。**但文件寫的 1 GB 最小值**並未被 API 強制**，所以由 plugin 自己守 | 拿到比要求的小，代表檔案系統會寫滿然後失敗。在這裡風險反轉了：沒有任何東西阻止一顆荒謬的小 LUN |
| R-5 | ~~LUN 的 `vpd_unit_sn` 在 Linux 變成什麼 WWID~~ **已解答，並在兩個獨立樣本上確認。**`WWID = "3" + "6001405" + uuid 把 `-` 換成 `d` 後的前 25 字元`，並以掛載中的 LUN 用 `scsi_id` 驗證 | 決定節點怎麼認自己的裝置。仍然只當交叉核對：plugin 依據的是核心自己的答案 |
| R-6 | ~~有快照的 LUN 能否刪除、有複本的快照能否刪除~~ **已解答：兩者都不拒絕，已對應的 LUN 也不拒絕。**快照跟著它的 LUN 走，不會變成孤兒 | 不需要清依賴——但「刪除前先解除對應」完全變成 plugin 的責任 |
| R-7 | ~~複本是精簡的還是完整複製~~ **已解答：精簡。**`clone_snapshot` 給出 `allocated_size: 0` 的 `BLUN` | 連結複本與範本是真的便宜 |
| R-8 | ~~`is_action_locked` 會維持多久~~ **已解答：**1 GiB 建立後 1.2 秒、複製空 LUN 0.0 秒、**複製內含 512 MiB 的 LUN 3.5 秒**、任何大小的快照 0.20 秒。建立後立刻刪除仍然成功 | 大型複製會超過天真的等待——CSI 自己的上限只有 20 秒，而幾百 GiB 的複製可能超過 |
| R-9 | ~~`LUN list` 有沒有伺服器端上限~~ **部分解答：`offset`／`limit` 被忽略，也不回報總數。**所以清單會回傳它手上的全部——而回應裡沒有任何東西能證明這一點 | **被靜默截斷的清單讀起來就是「全部就這些」**，而讀它的程式碼決定什麼可以刪。沒有總數可對照時，只有第二次讀取才抓得到短少的答案 |
| R-10 | **部分解答：**每個快照都帶 `taken_by`，而本 plugin 自己的標記原封不動回來，所以過濾是可行的。DSM **排程**拍的快照會不會出現在 `list_snapshot`，還需要設一個排程才能問 | 若會，PVE 會把使用者的排程快照當成自己的，而且可能刪掉它們 |
| R-11 | ~~每個 target 的 `mapping_index` 上限，以及會不會重用~~ **已解答：會重用。**被釋放的編號會給下一顆被對應的 LUN | 這就是「寫到別人的磁碟」那種錯誤，而卸離一顆磁碟再掛上另一顆就到得了。這也是為什麼裝置身分來自核心的 WWID，絕不來自路徑。上限本身仍未測 |
| R-12 | ~~DSM 能不能承受並行請求~~ **已解答：十六個同時發出的建立全部成功**，而陣列的內容與 API 回報的一致。每個約 1 秒，看起來 DSM 內部是序列化的 | Cinder 把每一個請求都包在行程級的鎖裡；這裡沒有任何東西為了正確性需要它 |
| R-13 | ~~同一帳號第二次登入會不會擠掉第一次~~ **已解答：不會。**兩個工作階段同時有效 | 錯誤碼 107 讓共用一個帳號的叢集本來很值得擔心 |

### 需要一個非管理員帳號才能回答

| # | 問題 |
|---|---|
| R-14 | 最小 DSM 權限。探索當時用的是管理員帳號，所以只證明了「管理員可以」，沒有證明「非管理員不行」。見 `DSM-ACCOUNT_zh-TW.md` |

### 設計上已支援，但未驗證——需要本專案手上沒有的硬體

Synology 兩種高可用性架構都已實作。兩種都沒有實際跑過。plugin 對無法驗證的架構 **發出警告**而不是拒絕，並且在有人回報實際運行結果之前，不會聲稱它驗證過。

| # | 問題 |
|---|---|
| R-15 | **Synology HA（SHA）**：HA 叢集 IP 在故障切換後是否仍表現為單一管理位址；以及本 plugin 拿來當 storage 身分的 `SYNO.Core.ISCSI.Node` uuid，切換後會不會變。如果會變，把 storage 釘在它上面就不是保護而是破壞 |
| R-16 | **UC／SA 雙控制器機型**（`firmware_ver` 含 `DSM UC`）：兩個控制器各有自己的管理位址，沒有浮動位址。`SYNO.Core.Network.Interface` 接受 `relay_node=node0`／`node1` 列舉對側——在單控制器的測試機上兩者回傳相同的介面，所以這個機制在不需要它的地方是無害的。**依 Synology 自己 CSI 的邏輯實作，但未驗證。**未解的問題正是只有機箱能回答的：一顆 LUN 是否由單一控制器擁有、target 的 portal 是否依控制器而不同——這兩件合起來決定故障切換後節點還找不找得到自己的磁碟 |

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

**前置條件。**一個專用的 DSM 儲存空間，或至少一個專用名稱前置字串；擁有者的明確同意；以及一份「絕對不可以碰」的 LUN 清單。每一步都可逆。

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

**Synology 的 multipath 和雙控制器無關。**單控制器機型是靠**多個網路 portal** 提供多重路徑的，而一台有兩張網路卡的 NAS 就足以做出真正的雙路徑 map。

測試機上從 `SYNO.Core.Network.Interface` 讀到的：

| 介面 | 位址 | 速度 | 狀態 |
|---|---|---|---|
| `ovs_eth0` | 192.0.2.10（靜態）| 1000 | connected |
| `ovs_eth1` | 192.0.2.11（**DHCP**）| 1000 | connected |

這已經是兩條可用的路徑了。但有三件事必須先弄對：

1. **target 的 `max_sessions` 要設成 0。**預設是 1，而一個工作階段就是一條路徑——所以停在預設值的 target 根本做不出 multipath，更不用說讓多節點共用。
2. **第二張介面要給靜態位址。**走 DHCP 的資料 portal 位址會變，而位址會變的路徑就是會消失的路徑。給它靜態位址，或在 DHCP 上做永久保留。
3. **這裡兩個位址在同一個子網路，而這是最麻煩的一點。**Linux 會很自然地把兩個工作階段都從路由表偏好的那張介面送出去，於是你得到的是「兩個工作階段走同一條物理線路」，一個看起來有備援但其實沒有的 map。要明確把每個工作階段綁到各自的介面上：

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

**不動 NAS 就能測故障切換。**從節點端把其中一個 portal 擋掉，然後觀察 map，不要拔線也不要去停用 NAS 的介面：

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

## 回報

如果你在自己的 NAS 上跑過上面任何一項，結果比這份文件裡的任何內容都有價值——尤其是型號或 DSM 版本和上面不同的時候，尤其是 R-1。請附上型號、DSM 版本、儲存空間的檔案系統，以及 NAS 的回應。
