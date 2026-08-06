# 測試與驗證

這份文件有兩個任務：說清楚**哪些事情真的驗證過、哪些沒有**，以及提供把後者搬到
前者的測試計畫。

它刻意寫得誠實。一個會默默猜測的 storage plugin 比一個會拒絕的更糟，所以每一項
陣列端的事實都標明來源，而任何無法確認的事情都會直說。

---

## 來源位階

| 階 | 來源 | 能證明什麼 |
|---|---|---|
| 1 | **實機** | 行為。唯一能回答「那真的刪掉了嗎」的一階 |
| 2 | **Synology 官方 CSI driver**（`SynologyOpenSource/synology-csi`） | 某個 API 存在，以及大致怎麼呼叫 |
| 2 | **OpenStack Cinder 的 Synology driver** | 同上，但是獨立的第二份——而且它知道 CSI 不知道的事 |
| 3 | **Synology 知識中心／SAN Manager 技術規格** | 產品限制 |
| 4 | **DSM Login Web API Guide** | 只有登入與 API 探索。它完全沒有記載任何 SAN API |
| — | 猜測 | 不是一階。不允許出現在程式碼裡 |

兩份第 2 階來源**彼此矛盾**，而矛盾的地方正是有價值的地方。工作階段的處理是最清楚
的例子：見下面「工作階段怎麼帶」。

---

## 測試硬體

| | |
|---|---|
| 型號 | DS918+ |
| DSM | 7.1.1-42962 Update 9 |
| 儲存空間 | `/volume1`，**Btrfs**，總量 14301.5 GiB |
| 註 | 這是一台**正式機**，同時也在跑 Virtual Machine Manager。目前為止只做過唯讀探索 |

**尚未做過任何寫入測試，也還沒有任何 plugin 程式碼。** 下面「已驗證」表格裡的每一
項都是唯讀取得的。

---

## 實機已驗證（2026-08-06，唯讀）

### 工作階段怎麼帶——兩份參考實作的做法不同，而其中一份在這裡是錯的

| 載體 | 在 DSM 7.1.1 上的結果 |
|---|---|
| `_sid` 表單參數（Cinder 的做法） | **119，SID not found——每一個呼叫都失敗** |
| `Cookie: id=<sid>` 標頭（CSI 的做法） | 可用 |

而且這個 cookie **不是伺服器設定的**：登入回應把 sid 放在主體裡，完全沒有
`Set-Cookie`，所以 cookie 必須由用戶端自己組出來。用 cookie jar 會得到一個空檔案，
然後每個呼叫都回 119——那看起來像登入壞了，但登入是好的。

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

- **`vpd_unit_sn` 就是 LUN 的 uuid，一字不差。** 那是 SCSI VPD 的單元序號，也就是
  Linux WWID 的來源。這代表 LUN 與裝置之間可以靠**核心自己的認定**對應，而不是只
  靠它被發現的路徑。兩份參考實作都只用 `/dev/disk/by-path`。
- **`restored_time` 存在**，這是「從快照還原 LUN」是一個真實且會被記錄的操作的
  證據——見未確認登記簿 R-1。
- `lun_id` 和 target 的 `mapping_index` 是**兩個不同的數字**。`mapping_index`
  **從 1 開始，不是 0**。

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

`6001405` 是 Linux-IO 的 IEEE 公司識別碼，所以 Synology 的 target 是 LIO 系的——
**但這不是原廠 LIO 的行為。** 上游的 `spc_gen_naa_6h_vendor_specific()` 用
`hex_to_bin()` 轉換序號，非十六進位字元會被**跳過**，那樣算出來是
`36001405a1b2c3d45e6f4a7b8c9d0e1f2`——而那不是 NAS 產出的值。Synology 是把連字號
映射成 `d`，不是丟掉。**照著上游原始碼推論會得到一個很有自信的錯誤答案**，只有實機
給了對的。

三個後果：

1. WWID **可以在裝置出現之前就算出來**，所以 multipath map 能確定性地釘住，而且節點
   能判斷「我找到的裝置是不是我要的那顆 LUN」——不必只相信它是從哪個路徑被發現的。
2. **uuid 的最後 11 個字元被丟掉了。** 所以 WWID 不是 uuid 的無損函式、不可反推，
   而且兩個只在尾端不同的 uuid 會撞同一個 WWID。隨機 uuid 下機率可忽略，但規則不變：
   算出來的值是**交叉核對**用的，最終認定要由核心自己的識別決定。
3. multipath `conf.d` drop-in 需要的兩個字串是 `vendor "SYNOLOGY"` 與
   `product "Storage"`。**兩個都不可能從 NAS 的 API 取得**——它們是 SCSI INQUIRY 的
   回應。猜錯會讓 drop-in 靜靜地不生效，而 `no_path_retry` 不生效就代表所有路徑消失
   時會無限排隊。

**一個樣本不足以證明一條規則。** 上面的規則精確重現了一個實測到的 WWID，這足以拿來
當交叉核對，但不足以拿來依賴。另外兩顆 LUN 的預測值記錄在非公開的文件裡，等第一次
掛上測試 LUN 時對照——如果規則是錯的，這一節會改，而 plugin 不論如何都會從核心讀回
WWID。

如果你手上有掛載中的 Synology LUN，這是五秒鐘就能做的貢獻：

```bash
# uuid 從 SAN Manager 或探索工具取得；WWID 在掛著它的主機上讀
ls -l /dev/disk/by-id/ | grep -i 6001405
```

### 一個不只是「未驗證」、而是「已驗證為不完整」的過濾條件

Synology 的 CSI driver 列出 LUN 時會送一個明確的十二種型態過濾條件
（`BLOCK`、`FILE`、`THIN`、`ADV`、`SINK`、`CINDER`…、`BLUN`、`BLUN_THICK`…）。
在測試機上，**那個過濾條件回傳 3 顆 LUN，而不帶過濾的列表回傳 4 顆**。被藏起來的
那一顆是：

```
type 295，VDISK_BLUN，120 GiB —— 一個 Virtual Machine Manager 的虛擬磁碟
```

它的 120 GiB 和其他東西吃的是同一個儲存空間，所以任何相信那個過濾條件的用戶端會
少算這麼多已配置空間，而且完全看不到這個物件。

**所以本專案從不送型態過濾條件。** 它不帶過濾地列出，然後在本地用名稱比對——而名稱
本來就是它唯一信任的所有權判準。探索工具現在會跑兩次列表並回報過濾條件藏了什麼，
因為下一台 DSM 可能藏的是別的型態。

這是那條通則的具體版本：**一個 plugin 要求過濾過的清單，必須被檢查它真的過濾了
什麼**，而「本來就沒有」和「被過濾掉了」在回應裡是分不出來的。

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

這改變了建立 LUN 的方式：`can_snapshot=1` 與 `emulate_tpu=1` 必須明確送出，否則
得到的是一顆拍不出快照、而且永遠不會把釋放的空間還回去的 LUN。**CSI 的
`dev_attribs` 完全由呼叫端給、自己一個預設都沒有；Cinder 一個都不送。** 兩份都不
可能告訴我們這件事——是實機告訴我們的。

### Target

`max_sessions` **預設是 1**，而停在 1 的 target 只容許一個節點登入。任何要讓 PVE
叢集共用的 target 都必須設成 0。

Target 的 IQN 裡嵌的是**建立當時**的 NAS 主機名稱——測試機上有帶著兩個不同主機名稱
的 target，因為它改過名。所以絕對不可以用「現在的主機名稱」去推導 IQN，再拿去和既
有的 target 比對。

### API 範圍

公佈 1184 個 API。SAN 相關全部在 `entry.cgi`、全部 `requestFormat=JSON`
（**每個參數都必須 JSON 編碼**）、全部只有 v1：
`SYNO.Core.ISCSI.{LUN,Target,Node,Host,FCTarget,Lunbkp,Replication,VMware}`、
`SYNO.Core.Storage.{Volume,Pool,iSCSILUN}`。`SYNO.API.Auth` 是 v1-7。

`SYNO.Core.ISCSI.Host`——IQN 存取控制物件——**存在且會回應**（`{"hosts":[]}`）。
兩份參考實作都不知道它在那裡。

這個型號上沒有 `SYNO.San.Nvme.*`，所以它不支援 NVMe-oF。

---

## 未驗證

這份清單裡沒有任何一項會被程式碼拿去行動。凡是 plugin 的決策依賴其中一項的，
plugin 一律拒絕而不是假設。

### 需要在實機上寫入才能回答

| # | 問題 | 為什麼重要 |
|---|---|---|
| R-1 | ~~從快照還原 LUN 的方法名稱~~ **已解答：`restore_snapshot`。** 剩下的是它的**參數名稱**，以及倒回後較新的快照是否保留、LUN uuid 是否不變 | 知道一個方法存在，不等於知道它做什麼。倒回若默默改掉 LUN uuid 就是改掉 WWID，每個節點看到的就是另一顆磁碟。**在行為被驗證之前倒回仍然拒絕，光知道名稱不算** |
| R-2 | `unmap_target` 是取代整份 target 清單還是加入 | 若是取代，解除一個節點的對應可能把全部節點一起解掉 |
| R-3 | LUN 名稱長度上限與合法字元 | 名稱承載所有權檢查。靜默截斷代表兩顆磁碟共用一個名字 |
| R-4 | 容量對齊粒度 | 拿到比要求的小，代表檔案系統會寫滿然後失敗 |
| R-5 | LUN 的 `vpd_unit_sn` 在 Linux 變成什麼 WWID | 決定節點怎麼認自己的裝置。已答一半：序號就是 uuid；核心端的字串還要在有連線的主機上讀 |
| R-6 | 有快照的 LUN 能否刪除、有複本的快照能否刪除 | `qm destroy` 和 vzdump 的快照模式都會直接撞上 |
| R-7 | 複本是精簡的還是完整複製 | 決定連結複本能不能做 |
| R-8 | `is_action_locked` 會維持多久 | 大型複製會超過天真的等待——CSI 自己的上限只有 20 秒 |
| R-9 | ~~`LUN list` 有沒有伺服器端上限~~ **部分解答：`offset`／`limit` 被忽略，也不回報總數。** 所以清單會回傳它手上的全部——而回應裡沒有任何東西能證明這一點 | **被靜默截斷的清單讀起來就是「全部就這些」**，而讀它的程式碼決定什麼可以刪。沒有總數可對照時，只有第二次讀取才抓得到短少的答案 |
| R-10 | `list_snapshot` 會不會回傳 DSM 排程自己拍的快照 | 若會，PVE 會把使用者的排程快照當成自己的，而且可能刪掉它們 |
| R-11 | 每個 target 的 `mapping_index` 上限，以及會不會重用 | 重用的編號配上核心裡殘留的舊裝置節點，屬於「寫到別人的磁碟」那一類 |
| R-12 | DSM 能不能承受並行請求 | **Cinder 把每一個請求都包在行程級的鎖裡。** 它不是沒事那樣做的 |
| R-13 | 同一帳號第二次登入會不會擠掉第一次（錯誤碼 107） | 若會，叢集裡每個節點會在每次輪詢互相擠掉對方 |

### 需要一個非管理員帳號才能回答

| # | 問題 |
|---|---|
| R-14 | 最小 DSM 權限。探索當時用的是管理員帳號，所以只證明了「管理員可以」，沒有證明「非管理員不行」。見 `DSM-ACCOUNT_zh-TW.md` |

---

## 測試計畫

### 階段 1——靜態，不需要 NAS

```bash
make release-check
```

語法、單元測試、與 CI 相同條件的整套測試、版本一致性、節點層級 multipath 守衛、
以及「憑證不得出現在 URL」守衛。

### 階段 2——逆境與惡意輸入，不需要 NAS

從相關專案移植，因為那裡的每一個案例都是曾經進到release 的缺陷：

- 一個會接受連線但永不回應、中途斷開主體、用 HTML 回 200、不回應就關閉、登入成功
  但不回 sid 的伺服器。每一種情況都必須**快速**失敗、指名是哪個 storage、而且絕不
  卡住。
- 一個以 5xx 失敗的 create 只被送出**一次**。
- 惡意輸入：帶路徑穿越與 shell 特殊字元的 storage id、每個邊界上的容量對齊、
  十六路並行配置。
- 對每個解析器餵入缺少的、改名的、型別錯誤的欄位——每個欄位名稱都必須安全地失敗，
  而不是被拿去行動。

### 階段 3——對真實 DSM 唯讀

```bash
bin/pve-syno-api-probe --host <nas> --user <帳號>
```

不建立、不刪除任何東西，跑完會自己登出。對正式機是安全的。確認：API 範圍、有可用
空間的 Btrfs 儲存空間、LUN 與 target 列表、`dev_attribs`，以及這台 DSM 是否開了
防 CSRF。

以下這一項可選，而且**只在取得擁有者同意後**執行：

```bash
bin/pve-syno-api-probe --host <nas> --user <帳號> --probe-methods
```

它會探測哪些快照還原方法名稱存在，做法是指名一個 NAS 從未發出過的 LUN 與快照
uuid——所以存在的方法只能拒絕，而拒絕的錯誤碼證明它在那裡。之所以要明確開啟，是
因為送出的畢竟是破壞性方法的名稱，即使它們能作用的對象並不存在。**R-1 就是這樣
回答的。**

### 階段 4——寫入，在沒有人在意的儲存空間上

**前置條件。** 一個專用的 DSM 儲存空間，或至少一個專用名稱前置字串；擁有者的明確
同意；以及一份「絕對不可以碰」的 LUN 清單。每一步都可逆。

1. 建立一顆帶 `can_snapshot=1`、`emulate_tpu=1` 的精簡 LUN。讀回 `type`、`size`、
   `dev_attribs`——回答 R-3、R-4。
2. 建一顆刻意超長名稱的，和一顆奇數容量的。
3. 對應到一個 `max_sessions=0` 的 target；從一個節點登入；讀
   `/dev/disk/by-id`、`/sys/block/sdX/device/wwid`——**回答 R-5**。
4. 把第二、第三顆 LUN 對應到同一個 target；解除中間那顆；再對應第四顆——回答
   R-2 與 R-11。
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

**Synology 的 multipath 和雙控制器無關。** 單控制器機型是靠**多個網路 portal**
提供多重路徑的，而一台有兩張網卡的 NAS 就足以做出真正的雙路徑 map。

測試機上從 `SYNO.Core.Network.Interface` 讀到的：

| 介面 | 位址 | 速度 | 狀態 |
|---|---|---|---|
| `ovs_eth0` | 192.0.2.10（靜態） | 1000 | connected |
| `ovs_eth1` | 192.0.2.11（**DHCP**） | 1000 | connected |

這已經是兩條可用的路徑了。但有三件事必須先弄對：

1. **target 的 `max_sessions` 要設成 0。** 預設是 1，而一個工作階段就是一條路徑——
   所以停在預設值的 target 根本做不出 multipath，更不用說讓多節點共用。
2. **第二張介面要給靜態位址。** 走 DHCP 的資料 portal 位址會變，而位址會變的路徑
   就是會消失的路徑。給它靜態位址，或在 DHCP 上做永久保留。
3. **這裡兩個位址在同一個子網路，而這是最麻煩的一點。** Linux 會很自然地把兩個
   工作階段都從路由表偏好的那張介面送出去，於是你得到的是「兩個工作階段走同一條
   物理線路」，一個看起來有冗餘但其實沒有的 map。要明確把每個工作階段綁到各自的
   介面上：

   ```bash
   iscsiadm -m iface -I path0 --op=new
   iscsiadm -m iface -I path0 --op=update -n iface.net_ifacename -v <網卡0>
   iscsiadm -m iface -I path1 --op=new
   iscsiadm -m iface -I path1 --op=update -n iface.net_ifacename -v <網卡1>

   iscsiadm -m discovery -t st -p 192.0.2.10 -I path0
   iscsiadm -m discovery -t st -p 192.0.2.11 -I path1
   iscsiadm -m node -T <target-iqn> -I path0 --login
   iscsiadm -m node -T <target-iqn> -I path1 --login

   multipath -ll        # 應該看到一個 map、兩條路徑，都是 active ready running
   ```

   分成兩個子網路或兩個 VLAN 是更乾淨的做法，交換器允許的話值得這樣做。DSM 也可以
   在同一個物理連接埠上建 VLAN 子介面，那會在一條線上產生兩個 portal 位址——足以
   把每一條程式路徑都跑過，但顯然不是真正的冗餘。

**不動 NAS 就能測故障切換。** 從節點端把其中一個 portal 擋掉，然後觀察 map，
不要拔線也不要去停用 NAS 的介面：

```bash
nft add table inet mptest
nft add chain inet mptest out '{ type filter hook output priority 0; }'
nft add rule inet mptest out ip daddr 192.0.2.11 tcp dport 3260 drop

multipath -ll        # 那條路徑必須變成 failed，而 I/O 必須繼續
nft delete table inet mptest      # 然後它必須恢復
```

要確認的是：全程 I/O 沒有中斷；規則移除後 map 會恢復；`no_path_retry` 是一個數字，
所以**所有**路徑都斷掉時是失敗而不是無限排隊；以及 plugin 在中斷期間所做的任何事
都沒有動到其他 storage 的 map。

**如果第二條路徑真的做不到**——單網卡機型——那就直說，不要假裝。單路徑的 map 仍然
會跑到 map 建立、WWID 釘定、擴充與 flush，但故障切換的路徑就是沒有測過，而這件事
應該寫在這份文件裡，不是寫在發行說明裡。

### 階段 6——故障注入

- 一個指向不可路由位址的 storage：其他 storage 保持 `active`，`pvesm status`
  只增加大約一個逾時的時間，不能更多。
- 操作進行中拔掉 NAS 的管理介面。
- 刻意設錯密碼：**只嘗試登入一次**，storage 回報需要人介入。自動封鎖不可以被觸發。
- 把 DSM 儲存空間填到剩餘不足 1 GB：配置被拒絕，訊息說得出原因。
- 停掉 multipathd；寫入過程中拔掉一條路徑。

### 階段 7——在節點上實地測試

安裝建置好的套件，並比對安裝前後的 `pvesm status`。除此之外不可以有任何狀態改變。
確認節點上其他 storage 未受影響——這個 plugin 是在一台同時跑 NetApp 與 Pure
Storage plugin 的節點上開發的——並確認沒有動到任何其他廠商的 multipath map。

---

## 回報

如果你在自己的 NAS 上跑過上面任何一項，結果比這份文件裡的任何內容都有價值——
尤其是型號或 DSM 版本和上面不同的時候，尤其是 R-1。請附上型號、DSM 版本、儲存
空間的檔案系統，以及 NAS 的回應。
