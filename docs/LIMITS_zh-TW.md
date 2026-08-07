# Synology 各機型的 LUN 與 target 上限

[English](LIMITS.md) · [繁體中文](LIMITS_zh-TW.md) · [文件網站](https://jasoncheng7115.github.io/jt-pve-storage-synology/?lang=zh)

**在這個 plugin 裡，一顆 VM 磁碟就是一個 LUN**。所以 LUN 上限不是註腳——它就是這個 storage 能容納的虛擬磁碟數量上限，而在某些機型上，這個數字會比其他任何限制更早成為瓶頸。

有三個容易被忽略的後果，而且三個講的都是「數量」而不是「容量」：

- **它是每台 NAS 一份，不是每個節點一份**。三個節點共用一台 NAS，就是共用同一個上限。
- **它數的是那台 NAS 上的每一個 LUN**，包括你在 SAN Manager 裡為了完全不相干的事建的那些。Plugin 也會把它們算進去，這正是它能在儲存伺服器之前先拒絕的原因。
- **一台 VM 通常不只用掉一個**。系統碟加資料碟就是兩個，所以公布 256 的機型大約放得下 **128 台這樣的 VM**；公布 4 的機型放得下**兩台**。

本頁每一個數字都引自 Synology 官方文件，並附上網址。沒有任何推算：Synology 沒有公布的地方，就寫沒有公布。

---


## 大家引用的那個數字是「產品線」的，不是你那台機型的

Synology 的 **SAN Manager 技術規格**頁面寫著：

| | |
|---|---|
| 最大 iSCSI target 數 | **256**（見限制 1）|
| 最大 LUN 數 | **512**（見限制 1）|
| 每個 LUN 最大快照數 | **256**（見限制 1）|
| 最小 LUN 大小 | **1 GB** |

> **限制 1**——「LUN、target 與快照的最大數量會依機型而異（請參閱您 Synology 產品的軟體規格）」

——[SAN Manager 技術規格，DSM 7.1](https://www.synology.com/zh-tw/dsm/7.1/software_spec/san_manager)（[DSM 7.3](https://www.synology.com/zh-tw/dsm/7.3/software_spec/san_manager) 頁面文字相同）

所以 **512 和 256 是整條產品線的上限**。除非你那台 NAS 自己的規格表這樣寫，否則那不是你的數字。

### 第二個機型、第二個 DSM 版本，回報方式完全一樣

從一台 **DS925+**（DSM 7.3.2-86009 Update 4）讀取 `SYNO.Core.System info type=define`——那是與本專案其餘部分所依據的 DS918+／7.1.1 不同的機型，也是不同的 DSM 主版本：

| | DS918+ · DSM 7.1.1 | DS925+ · DSM 7.3.2 |
|---|---|---|
| `max_iscsiluns` | 256 | **256** |
| `max_iscsitrgs` | 128 | **128** |
| `max_snapshot_per_lun` | 256 | **256** |
| `iscsi_target_type` | lio4x | **lio4x** |
| `type=define` 的鍵數 | 316 | **346** |
| `SYNO.API.Auth` | v1-7，在 `entry.cgi` | **v1-7，在 `entry.cgi`** |

這個 plugin 用到的每一個 API 在 7.3.2 上都存在，版本與 CGI 路徑都相同，**包括 `SYNO.API.Auth` 在 `entry.cgi`**，而不是兩份公開參考實作寫死的 `auth.cgi`。那正是「問 `SYNO.API.Info` 而不是用常數」要防的東西，而在此之前它從來沒有在第二個 DSM 版本上被檢查過。

### 規格表和 API 之間沒有落差

這個專案先前記載說有，而那是錯的。測試用的機器是 DS918+：

| 來源 | 最大 LUN 數 | 最大 target 數 |
|---|---|---|
| SAN Manager 軟體規格（整條產品線）| 512 | 256 |
| [DS918+ 產品規格](https://global.download.synology.com/download/Document/Hardware/ProductSpec/DiskStation/18-year/DS918+/enu/Product_Spec_DS918+_enu.pdf) | **256** | **128** |
| 該機器上的 `SYNO.Core.System info type=define` | **256** | **128** |

機型的規格表和 NAS 自己的 API **完全一致**。不一致的是這份文件——它拿機型去比對一個產品線層級的數字。

---

## 各機型公布的數字

引自每個機型自己的規格表或產品規格 PDF。所有網址都在 `https://global.download.synology.com/download/Document/Hardware/` 底下。

| 系列 | 機型 | 最大 LUN | 最大 target |
|---|---|---:|---:|
| **FS** | FS6400 | 512 | 256 |
| | FS3600 | 512 | 256 |
| | FS3410 | 256 | 128 |
| | FS2500 | 128 | 64 |
| **SA** | SA6400 | 512 | 256 |
| | SA3600 | 512 | 256 |
| | SA3410 | 256 | 128 |
| | SA3400D | 256 | 128 |
| | SA3200D | 128 | 64 |
| **XS+／XS** | DS3622xs+ | 256 | 128 |
| | RS4021xs+ | 256 | 128 |
| | RS3621xs+ | 256 | 128 |
| | RS3618xs | 128 | 64 |
| **Plus** | DS1821+ | 256 | 128 |
| | **DS925+**（直接從 NAS 讀到）| **256** | **128** |
| | DS923+ | 256 | 128 |
| | DS920+ | 256 | 128 |
| | **DS918+**（測試機）| **256** | **128** |
| | DS723+ | 256 | 128 |
| | DS1825+ | **128** | **64** |
| | RS2825RP+ | 128 | 64 |
| | RS1221+ | 128 | 64 |
| | DS425+ | **4** | **2** |
| | DS423+ | *未公布* | *未公布* |
| **Value** | DS423 | 4 | 2 |
| | DS223 | 4 | 2 |
| | DS218play | 10 | 10 |
| **J** | DS223j | 4 | 2 |
| | DS124 | 4 | 2 |

### 這張表要看的是形狀，不是查你自己的機型

表裡有三件事比任何單一列都重要。

**系列不能預測數字**。這些數字集中在 4／2、128／64、256／128、512／256，但 Synology 是逐機型指定的，而且沒有公布任何系列層級的規則。一台「Plus」機型可能是 256、128，也可能是 4。

**數字和世代不是單調的**。**DS1825+**（2025 年、八槽 Plus）公布的是 **128／64**，而更舊的 **DS1821+** 公布 **256／128**。**RS3618xs** 公布 128／64，而 **RS3621xs+** 公布 256／128。更新或更大的機型不代表更大的數字。

**在 J、Value 和某些小型 Plus 機型上，上限是 4 個 LUN**。DS425+、DS423、DS223、DS223j、DS124 公布的是 **4 個 LUN、2 個 target**。在這個 plugin 裡，那就是**整個 storage 只有四顆虛擬磁碟**——一台有系統碟和資料碟的 VM 就用掉一半。這些機型可以跑這個 plugin，而且會在空間用完之前很久就先用完 LUN。

---

## 所以要問 NAS，而這個 plugin 就是這樣做的

`SYNO.Core.System` 的 `info`（`type=define`）會回報機型自己的上限。兩份公開參考實作都沒有讀它。從測試用的 DS918+ 讀到的：

```
max_iscsiluns          256
max_iscsitrgs          128
max_snapshot_per_lun   256
max_btrfs_snapshots    65536
support_iscsi_btrfs_lun    yes
iscsi_target_type          lio4x
```

這個 plugin 會讀三個上限，並且在 NAS 之前先拒絕，讓訊息說出真正的原因，而不是一個錯誤號碼：

| 上限 | plugin 的行為 |
|---|---|
| LUN | 拒絕配置，並在剩下 16 個時開始警告。計數包含 NAS 上**每一顆** LUN，包括這個 storage 不擁有的 |
| 每個 LUN 的快照 | 拒絕快照。計數包含該 LUN 上**每一個**快照，包括 SAN Manager 排程拍的——這個上限是共用的 |
| target | 拒絕建立 target。只有在 `syno-target-mode=per-volume` 時才會走到；`shared` 整個 storage 只用一個 target，而這正是它作為預設值的理由 |

三者任一回傳 `undef` 代表 NAS 沒有回報，而防護會退下，不會自己編一個數字。它永遠不代表「沒有上限」。

### 為什麼 `shared` 是預設的 target 模式

在一台公布 256 個 LUN、128 個 target 的機型上，`per-volume` 會讓每顆磁碟各有一個 target——所以 target 上限會在 **128 顆磁碟時就到，只有 LUN 允許數量的一半**。`shared` 每個 storage 只用一個 target，讓 LUN 上限成為唯一的限制。

---

## 每個 LUN 的快照數，以及一個共用的額度

**每個 LUN 256 個**，來自 SAN Manager 技術規格頁面，帶著同樣的「依機型而異」註腳。測試用的 DS918+ 回報 256。

關於這個數字有兩件事：

- **它和 SAN Manager 共用**。在 DSM 裡設定的快照排程會吃掉同一個 256。這個 plugin 計數時會算該 LUN 上每一個快照，不只是自己的，正是為了這個原因。
- **檢視過的規格表都沒有列出每個 LUN 的快照數字**。規格表上的「每個共用資料夾最大快照數」（128／512／1,024）和「系統最大快照數」（1,024／4,096／16,384／65,536）是 Snapshot Replication 針對另一種物件的欄位。DS918+ 的規格表根本沒有「每個 LUN 快照數」這一列。不要把那些數字當成 LUN 的上限。

---

### 含記憶體的快照會自己吃掉一顆 LUN

勾選**包含記憶體**之後，Proxmox VE 會把記憶體寫進一顆獨立的磁碟 `vm-<vmid>-state-<快照名稱>`——在這個 storage 上那就是**另一顆 LUN**，算在同一個上限裡。有兩件事讓它比一般人想的大：

- 它的容量是 **VM 記憶體的兩倍再加 500 MB**，因為 PVE 要留出空間把儲存完成、又不讓 guest 停太久。一台 8 GiB 的 VM 會要一顆 **16.5 GB** 的 LUN。
- **它預設就會落在這裡**。`find_vmstate_storage` 偏好「VM 已經有磁碟在上面的**共用** storage」，而這個 storage 一定是共用的。要放到別的地方，就在該 VM 上設定 `vmstatestorage`。

快照刪除或倒回之後它會被釋放。這是實機跑出來的：plugin 認得那個名稱，把 state 磁碟當成一般的 LUN 處理。

## LUN 類型改變的是「能做什麼」，不是「能有幾個」

Synology 對 LUN 類型的相依性只針對**功能**做了記載，從來不是針對數量。摘自 SAN Manager 規格頁面：

- 快照與空間回收在**厚配置 LUN 上不支援**
- **只有 Btrfs 儲存空間上的精簡配置 LUN，在 DSM 6.2 以上，才支援即時快照與還原**
- 只有 Btrfs 精簡配置 LUN 支援磁碟重組
- iSCSI LUN 複製／快照只在特定機型上可用

這就是為什麼這個 plugin 要求 Btrfs 儲存空間，而且在 `pvesm add` 就拒絕，而不是等到你第一次拍快照。沒有任何官方資料指出精簡與厚配置的最大 LUN 數不同。

---

## 沒有公布的部分

直接寫出來，因為一個空白比一個猜測有用：

- **每個 target 的最大工作階段數沒有公布**。官方沒有任何地方說明預設值或上限。預設值只容許一個節點、而叢集需要 `max_sessions=0`，這些只有實機量測——見 `TESTING_zh-TW.md`。
- **沒有「最大 LUN 數量是多少」這種形式的知識中心文章**。SAN Manager 的說明頁面存在，而且會叫你去看自己機型的規格表，但它的內文是用戶端算繪的，並沒有被直接讀取：[LUN](https://kb.synology.com/zh-tw/DSM/help/ScsiTarget/lun?version=7) · [iSCSI](https://kb.synology.com/zh-tw/DSM/help/ScsiTarget/iscsi?version=7) · [快照](https://kb.synology.com/zh-tw/DSM/help/ScsiTarget/snapshot?version=7)
- **上限和 DSM 版本或記憶體容量沒有任何關聯**。檢視過的每一份規格表都查過有沒有這樣的註腳，都沒有。唯一和記憶體有關的數字是 SMB 同時連線數。
- **DS423+ 根本沒有公布數字**。它不等於 DS423——它是未知。
- **UC3200、SA3400 以及最新的 XS+ 機架機型**沒有取得；它們的規格表網址在其他機型可用的規則下無法解析。是未知，而不是不存在，而這和 `TESTING_zh-TW.md` 裡未驗證的 UC 支援有關。

---

## 官方參考資料

- [SAN Manager 技術規格——DSM 7.1](https://www.synology.com/zh-tw/dsm/7.1/software_spec/san_manager)
- [SAN Manager 技術規格——DSM 7.3](https://www.synology.com/zh-tw/dsm/7.3/software_spec/san_manager)
- [DS918+ 產品規格（PDF）](https://global.download.synology.com/download/Document/Hardware/ProductSpec/DiskStation/18-year/DS918+/enu/Product_Spec_DS918+_enu.pdf)
- [DS923+ 規格表（PDF）](https://global.download.synology.com/download/Document/Hardware/DataSheet/DiskStation/23-year/DS923+/enu/Synology_DS923+_Data_Sheet_enu.pdf)
- [DS1825+ 規格表（PDF）](https://global.download.synology.com/download/Document/Hardware/DataSheet/DiskStation/25-year/DS1825+/enu/Synology_DS1825+_Data_Sheet_enu.pdf)
- [FS6400 規格表（PDF）](https://global.download.synology.com/download/Document/Hardware/DataSheet/FlashStation/20-year/FS6400/enu/Synology_FS6400_Data_Sheet_enu.pdf)
- [SA6400 規格表（PDF）](https://global.download.synology.com/download/Document/Hardware/DataSheet/SA/22-year/SA6400/enu/Synology_SA6400_Data_Sheet_enu.pdf)
- [DS3622xs+ 規格表（PDF）](https://global.download.synology.com/download/Document/Hardware/DataSheet/DiskStation/22-year/DS3622xs+/enu/Synology_DS3622xs+_Data_Sheet_enu.pdf)
- [Synology 產品總覽](https://www.synology.com/zh-tw/products)——每個機型自己的規格表都在它的產品頁面上，而那才是你那台 NAS 該相信的數字

**要查你自己的 NAS 而不是查表：**

```bash
pve-syno-api-probe --host <nas> --user <帳號>
```

它會回報該機型的上限，不建立也不刪除任何東西。
