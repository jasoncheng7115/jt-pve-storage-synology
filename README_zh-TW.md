# jt-pve-storage-synology

透過 iSCSI 連接 Synology NAS 的 Proxmox VE 儲存 plugin。**一顆 VM 磁碟就是 NAS 上一個精簡配置 LUN**，所以 DSM 自己的快照、複本與容量都作用在操作者心裡想的那個單位上——沒有 LVM 夾層，也不把一個共用 LUN 在本機切開。

[English](README.md) · [繁體中文](README_zh-TW.md) · **[文件網站](https://jasoncheng7115.github.io/jt-pve-storage-synology/?lang=zh)**

---

> ### 狀態：**它在叢集上可以用，而且被操得很兇。**
>
> 以下每一項都對一台 DS918+（DSM 7.1.1）實際跑過：完整的磁碟生命週期、一台**從 NAS 開機**的 guest、三種 `vzdump` 模式的備份都還原成完全相同的位元組、**跨三個節點的即時遷移**（中斷 5 毫秒與 87 毫秒），以及一個當掉節點的 LUN**由存活節點在 3.6 秒內接手**，而當時死掉節點的工作階段仍然登記在 NAS 上。兩個 portal 的 multipath 在路徑故障期間**60 次讀取失敗 0 次**，而一次 DSM 管理連線中斷讓 guest 出現**零個 I/O 錯誤**。
>
> 仍然該誠實說的是：**一個**機型、**一個** DSM 版本，從來沒有任何 Synology HA 或雙控制器機箱接近過它，而那個 DSM 帳號需要管理員權限——因為 DSM 7.1.1 沒有更窄的選擇，非管理員連登入都過不了。從實際運行中找出大約二十五個「讀程式碼永遠讀不出來」的缺陷，所以請假設還有更多。
>
> `1.0.0` 在等的是：第二個機型、第二個 DSM 版本，以及確定最小的 DSM 權限。[docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 是那份「哪些驗證過、哪些沒有」的登記簿，在信任這個東西之前值得讀一遍。

---

## 為什麼有這個專案，以及麻煩在哪裡

Synology 沒有公開 SAN Manager Web API 的規格。唯一的官方文件——DSM Login Web API Guide——只涵蓋登入與 API 探索，完全沒有記載任何 LUN、target、對應或快照的呼叫。

真正存在的是兩份在生產環境和它對話的獨立實作：

- **Synology 官方的 CSI driver**，[SynologyOpenSource/synology-csi](https://github.com/SynologyOpenSource/synology-csi)（Apache-2.0）
- **OpenStack Cinder 內建的 Synology driver**，在 [Cinder](https://github.com/openstack/cinder) 的原始碼樹裡（Apache-2.0）

這個專案的事實來自**把這兩份互相對讀**，然後再去問實機。最後那一步很重要：兩份的做法有出入，而只要有出入，在任一台特定的 DSM 上至少有一份是錯的。在用來測試的 DSM 7.1.1 上，**Cinder 帶工作階段的方式完全不能用**，而在開啟防 CSRF 的 DSM 上 **兩份都沒有送 NAS 要求的那個 token**。

凡是無法確認的地方，這個 plugin **拒絕該操作**，而不是猜。`docs/TESTING_zh-TW.md` 就是那份登記簿，而且它會被誠實地維護。

從那兩個專案取用的只有協定事實——API 名稱、方法名稱、參數、錯誤碼。沒有任何程式碼衍生自它們；本專案是 Perl，結構是自己的。

## 它將會做的事

| PVE 操作 | 在 NAS 上 |
|---|---|
| 建立磁碟 | 在 Btrfs 儲存空間上建立精簡（`BLUN`）LUN，並開啟 `can_snapshot` 與 UNMAP |
| 刪除磁碟 | 先解除對應再刪除，並且先刪掉它自己的快照 |
| 擴充磁碟 | LUN 擴充，然後在每個節點做有界的逐裝置重新掃描 |
| 快照 | DSM 的 LUN 快照，並加上標記，絕不與使用者自己的快照混淆 |
| 複製 | 從 LUN 或它的某個快照複製 |
| **倒回** | `restore_snapshot`。LUN 的 uuid 不變，較新的快照也存活 |
| 掛上／卸離 | iSCSI 登入，裝置由核心自己的識別找出，dm-multipath |

### 倒回，以及為什麼繞了一段路才走到這裡

兩份參考實作都沒有快照倒回：Kubernetes 與 Cinder 都是用「把快照複製成一個**新的** volume」來還原，所以兩者都不需要。這個方法是靠對一台 DSM 詢問九個候選名稱找到的，其中一個回答了——**`restore_snapshot`**，收 `src_lun_uuid` 與 `snapshot_uuid`。

但找到名稱還不足以把它打開，因為有三件事必須成立，而事先沒有一件是可知的：

| | |
|---|---|
| LUN 的 uuid 不可以變 | **它不會變**。所以 SCSI 序號與 WWID 都存活，節點不會突然在自己磁碟的位置上找到另一顆 |
| 比還原點更新的快照必須存活 | **會存活**。還原到三個之中最舊的那一個，三個都還在 |
| 事後必須看得出來 | `restored_time` 會記錄還原當下的 epoch 秒 |

第二件正是相關專案**拒絕**越過較新快照倒回的原因：在那些陣列上較新的快照會被銷毀，所以讓 PVE 默默做那件事的 plugin，等於刪掉使用者還看得到的快照。這裡什麼都不會被銷毀，所以那道限制不需要，一顆磁碟也可以反覆倒回。

## 需求

| | |
|---|---|
| DSM | **7.0 以上**，而且只驗證過 7.1.1。雙控制器的 DSM UC 會被**拒絕**，不會假裝支援。見下——版本號只是門檻，不是判準 |
| 儲存空間 | **Btrfs**。快照只存在於 Btrfs 上的精簡 LUN——ext4 的儲存空間在加入 storage 時就被拒絕，而不是等到第一次拍快照才失敗 |
| 型號 | 支援 iSCSI target 且有足夠可用空間者。**LUN 上限是看機型的，而且某些機型很小**——DS425+ 或任何 J／Value 機型公布的是 **4 個 LUN**，也就是整個 storage 只有四顆虛擬磁碟。附出處的表格：[docs/LIMITS_zh-TW.md](docs/LIMITS_zh-TW.md) |
| 網路 | 以 HTTPS 連到 DSM（5001）。純 HTTP 一律拒絕 |
| 帳號 | 一個專用的 DSM 帳號——見 **[docs/DSM-ACCOUNT_zh-TW.md](docs/DSM-ACCOUNT_zh-TW.md)**，其中也說明了 DSM 唯一不讓你限制的那件事 |
| PVE | 8.x／9.x。儲存 API 版本是協商出來的，從不寫死 |

### DSM 版本只是門檻，不是判準

**要求 7.0 以上**。技術下限其實更低——Cinder 的 driver 一路支援到 DSM 6.0.2，而 Btrfs 精簡 LUN 的快照從 6.2 就有——所以 7.0 是刻意選的保守值，理由有四個：SAN Manager 是 7.0 才有的產品，6.x 是 iSCSI Manager；本 plugin 需要的存取控制物件只在 7.x 上見過；**Synology 自己的 CSI driver 就要求 7.0 以上**，那是 Synology 自己會拿 API 用戶端去實際跑的範圍；而 DSM 6.2 已經 EOL，不管 API 通不通，拿它跑生產儲存都不該被建議。

真正驗證過的只有 **7.1.1-42962 Update 9**。7.0 到那之間應該可以用，但沒試過。

**但版本檢查通過不代表這台 NAS 能用**，而這件事比那個數字重要：

| 真正決定的東西 | 為什麼它比版本號可靠 |
|---|---|
| `SYNO.Core.System` 的 `support_iscsi_target`、`supportsnapshot`、`support_storage_mgr` | 這些描述的是**機型**，不是 OS 版本 |
| `SYNO.API.Info` 有沒有公佈需要的 API | 測試機跑 7.1.1，卻完全沒有 NVMe-oF 的 API。沒有任何版本號看得出這件事 |
| 儲存空間是不是 **Btrfs** | 比 DSM 版本更嚴的限制：**Btrfs 支援是看機型的**，沒有 Btrfs 的入門機不管哪一版 DSM 都拍不出快照 |

所以一台跑 7.2 的入門機仍然可能不能用，而只讀版本號的檢查不會說出原因。plugin 會四項全查，並指出是哪一項不過。

## 最多可以切幾個 LUN，以及開到上限會怎樣

一顆 VM 磁碟就是一個 LUN，所以 LUN 的上限是實實在在的容量限制——而它不是技術規格表上那個數字。

**問 NAS。**`SYNO.Core.System` 的 `info`（`type=define`）會回報機型自己的上限，而兩份公開的參考實作都沒有讀它：

| 鍵 | 測試機 DS918+ | DS918+ 規格表 | SAN Manager 規格（整條產品線）|
|---|---|---|---|
| `max_iscsiluns` | **256** | 256 | 512 |
| `max_iscsitrgs` | **128** | 128 | 256 |
| `max_snapshot_per_lun` | 256 | *未公布* | 256 |

所以 NAS 的 API 和它自己的規格表**是一致的**；512 是整條產品線的上限，而 Synology 註明它依機型而異。更大的機型會回報更大的數字，更小的機型少到只有 **4 個**；重點是這個數字是看機型的，而且 NAS 會告訴你哪一個適用。附出處的完整表格在 [docs/LIMITS_zh-TW.md](docs/LIMITS_zh-TW.md)。

### 開到上限會怎樣

DSM 會乾淨地拒絕——LUN 是 **18990541**、target 是 **18990542**、快照是 **18990543**。什麼都不會壞。但那個拒絕到操作者眼前是「配置失敗」加一個五位數字，而 `pvesm status` 還繼續顯示好幾 TB 可用——因為可用空間不是問題所在，加硬碟也解決不了。

### 所以 plugin 會先拒絕

在請 NAS 建立任何東西之前，它會把 LUN 數量和 `max_iscsiluns` 比對，然後用一句說得出真正原因的話拒絕：NAS 已經放到這個機型的 LUN 上限，唯一的解法是刪掉一些。剩下不到十六個時它也會警告一次，那時候還來得及規劃。

**這個數量包含不屬於這個 storage 的 LUN**——擁有者自己的 LUN、以及任何 Virtual Machine Manager 的虛擬磁碟，全都吃同一個上限。這就是本 plugin 從不送 Synology 自己那份型態過濾條件的第二個理由：那個過濾條件藏起來的正是這些物件，所以任何相信它的用戶端，會在它正在檢查的那個上限上少算。

### 三個上限，按照會先咬到你的順序

1. **LUN**——每顆 VM 磁碟一個。對一個忙碌的 storage 來說，這是真正的限制。
2. **每顆 LUN 的快照 256 個，而且和使用者自己的排程共用額度**。一顆設了 SAN Manager 快照排程的 LUN，留給 PVE 的就更少，而「拍不出快照」不會明顯看起來和那件事有關。
3. **Target**，這台是 128 個。在預設的 `shared` target 模式下無關緊要，因為只用一個——而這也正是 `per-volume` 不是預設的原因：它會把 storage 卡在 128 顆磁碟，**低於** LUN 的上限。

## 高可用性與雙控制器

Synology 有兩種都被叫做「HA」的架構，但它們是兩個不同的問題、有不同的答案。**兩種都支援。**

| | **Synology HA（SHA）**| **UC／SA 雙控制器** |
|---|---|---|
| 架構 | 兩台機箱，主／備 | 一個機箱兩個控制器 |
| 偵測方式 | —| `firmware_ver` 含 `DSM UC` |
| 管理位址 | **一個浮動的叢集 IP** | **每個控制器各一個，沒有浮動位址** |
| 設定方式 | `--syno-portal <叢集 IP>` | `--syno-portal <控制器 A>,<控制器 B>` |
| 最接近的類比 | Pure Storage 的 `vir0` | PowerVault ME 的兩個控制器位址 |

`syno-portal` 收一份清單，依序嘗試、失敗就輪替。輪替發生在登入**裡面**，而請求的 URL 是在輪替之後才組——相關專案出過一個缺陷：URL 先組好了，所以每次重試都繼續送往剛剛才被判定死掉的那個位址。

UC 機箱的第二個位址不必手動設定：`SYNO.Core.Network.Interface` 接受 `relay_node=node0` 與 `node1`，可以列舉對側控制器的介面。在單控制器的 NAS 上兩者回傳相同的介面，所以這個機制在不需要它的地方是無害的。那些機型上，target 的 `network_portals` 還會帶 `controller_id`，而單控制器的 NAS 完全不回傳這個欄位。

### 兩種都沒有在實機上跑過，而 plugin 會說出這件事

SHA 風險低：它就是一個會移動的位址，而那正是 plugin 已經處理的情況。UC 是真正的未知，而未解的問題正是只有機箱能回答的——一顆 LUN 是否由單一控制器擁有、target 的 portal 是否依控制器而不同。這兩件合起來決定故障切換之後節點還找不找得到自己的磁碟。

所以 plugin 偵測到 `DSM UC` 時**發出警告**而不是拒絕，而這一頁會一直寫著「未驗證」，直到有人回報實際運行結果。兩者在登記簿上是 R-15 與 R-16。

**如果你手上有其中任何一種，最有價值的回報是一個數字**：`SYNO.Core.ISCSI.Node` 的 uuid 在故障切換之後還是同一個嗎？storage 的身分釘在它上面，所以如果它會變，那道釘子就不再保護 storage，而是開始破壞它。

## 安裝

叢集的每一個節點都要裝。

```bash
# 每個節點都要 —— PVE 不會替你裝的兩個套件
apt update
apt install -y open-iscsi multipath-tools

cd /tmp
wget https://github.com/jasoncheng7115/jt-pve-storage-synology/releases/latest/download/jt-pve-storage-synology_all.deb
apt install ./jt-pve-storage-synology_all.deb
```

不需要重啟服務，而這是實測出來的，不是假設的。這個套件會安裝到 `/usr/share/perl5/PVE` 底下，而 `pve-manager` 用一個 `interest-noawait` trigger 監看那個路徑——就是輸出裡「Processing triggers for pve-manager」那一行——它的 postinst 會對 `pvedaemon`、`pvestatd`、`pveproxy`、`spiceproxy`、`pvescheduler` 執行 `reload-or-try-restart`。reload 就夠了：把套件移除後，`pvedaemon` 的可用 storage 類型清單裡沒有 `synologysan`；裝回去之後 daemon 立刻就會驗證 `synologysan` 的選項——而全程它的 PID 都沒有變。如果有什麼東西擋住 `deb-systemd-invoke`，備援做法是 `systemctl restart pvedaemon pveproxy pvestatd`。


> **每個節點的版本要一致**。一個 storage 操作是在**擁有那個 guest 的節點**上執行的，用的是**那個節點上的** plugin——不是你瀏覽時所連的那一台。所以版本混雜的叢集，行為會隨著 VM 剛好在哪裡而不同，而症狀很難懂：你明明裝好的修正，對某些 guest 就是不存在。在每個節點上用 `dpkg -l jt-pve-storage-synology | awk '/^ii/{print $3}'` 確認。

> **每個節點都要裝，否則這個 storage 在網頁介面上看不到**。`pvesm add` 寫的是叢集設定，所以在一個節點上執行就足以建立這個 storage——但網頁介面是由**你的瀏覽器所連上的那個節點**提供的，而 `pveproxy` 在啟動時就把 plugin 清單載入了。沒有裝 plugin 的節點不認得 `synologysan` 這個類型，於是**會把這個 storage 從清單裡靜靜略過**。在有裝的節點上它是存在而且可用的，只是沒有被顯示出來——而這個症狀看起來就像 `pvesm add` 失敗了，但它並沒有。每個節點都要裝，而且每一台都要重啟服務，包含你正在瀏覽的那一台。若要先限制在已就緒的節點上：`pvesm set <storage> --nodes nodeA,nodeB`。

> **如果你已經用 `dpkg -i` 失敗過**。本頁先前的版本寫的是 `dpkg -i`。那會讓套件解開但「未設定」，而 apt 接著就拒絕求解任何其他東西——你會看到 `Unmet dependencies`，說 `kpartx` 和 `sg3-utils-udev`「not going to be installed」，看起來像套件庫的問題，但不是。先執行 `dpkg --remove jt-pve-storage-synology`，然後再跑上面那段。如果清掉之後前置套件還是裝不起來，用 `apt policy kpartx sg3-utils-udev` 檢查——`kpartx` 來自 Debian 的 `trixie/main`，而 `sg3-utils-udev` 來自 Proxmox VE 的套件庫。

`open-iscsi` 和 `multipath-tools` 是 Proxmox VE 節點真的可能沒有的兩個——PVE 不會拉進它們，而安裝 `multipath-tools` 正是那個維護時段真正在做的事。這個套件另外需要的四個 Perl 模組，各自是 86 到 151 個 PVE 套件的相依，所以一定已經在了。

然後用 `apt install ./…`，不是 `dpkg -i`：`dpkg` 不會處理相依性——在沒有 `multipath-tools` 的節點上，它會解開套件然後以「dependency problems —leaving unconfigured」失敗。前面的 `./` 是必要的，否則 apt 會把它當成套件名稱。

那個網址永遠指向最新的發行版，所以不會過期——從 0.6.4 起 `beta1` 字樣拿掉了，發行版不再被標記為預發行版（GitHub 的 `latest` 原本會跳過那些），而且每一次發行都會用這個不帶版本號的名稱額外發布一份。若要固定版本，請從[發行頁面](https://github.com/jasoncheng7115/jt-pve-storage-synology/releases)取用網址。從 clone 安裝則是 `make install`。

> **第一次安裝請排維護時段**。`activate_storage` 會寫一個對應 `vendor "SYNOLOGY"` 的 multipath drop-in，而當那個檔案變更時會執行 `multipathd reconfigure`——那是**節點層級**的。它只在檔案第一次出現或變更時執行一次。這個 drop-in 是必要的，不是調校：沒有它就會套用 multipath 的通用預設值，而那包含 `no_path_retry "queue"`，會把「失去所有路徑」變成一個殺不掉的行程，而不是一個 I/O 錯誤。

四支這樣的 plugin 可以共存於同一個節點——但 `PVE::SectionConfig::init` **遇到重複的屬性名稱會直接 die**，屆時節點上每一個 storage 都會停止運作。`syno-` 這個前置字串就是為此存在的。

## 設定 storage

在其中一個節點上執行一次就好。這個 storage 依其本質就是共用的。

```bash
pvesm add synologysan mysyno \
    --syno-portal   192.0.2.10 \
    --syno-username pve-storage \
    --syno-password '<密碼>' \
    --syno-location /volume1 \
    --content       images \
    --nodes         pve1,pve2,pve3    # 選用：限制在這幾個節點
```

### 只讓某幾個節點可以用

`nodes` 是 Proxmox VE 自己的屬性，不是 `syno-` 開頭的，而它在這裡和在其他 storage 上一樣有效：

```bash
pvesm set mysyno --nodes pve1,pve2     # 限制一個既有的 storage
pvesm set mysyno --delete nodes        # 重新開放給整個叢集
pvesm status --storage mysyno          # 確認
```

有兩個理由要用它。**沒有裝 plugin 的節點**否則會在每一次 `pvestatd` 輪詢時記錄「unknown storage type」——限制節點是分批上線最乾淨的做法。而**連不到 NAS 資料 portal 的節點**本來就不該去嘗試；它會在啟用磁碟時失敗，而不是禮貌地略過。

`shared` 是強制開啟、不能關掉的——這個 plugin 會把自己註冊進 `SHARED_STORAGE`，因為 NAS 上的 LUN 依其本質就是每個節點都連得到的。所以 `nodes` 限制的是**哪些節點可以使用它**，絕不會讓這個 storage 變成節點本機的。在清單允許的任何兩個節點之間，即時遷移都可以運作。

如果那個儲存空間不是 Btrfs、機型不支援 iSCSI target 或快照、或者這個 storage id 會摺疊成與既有 storage 相同的 LUN 前置字串，`pvesm add` 會當場拒絕。

**密碼不會進到 `/etc/pve/storage.cfg`**。它會寫到 `/etc/pve/priv/storage/<storage>.syno`，權限 `0600`、只有 root、並複寫到每個節點。完整選項清單與移除程序：[文件網站](https://jasoncheng7115.github.io/jt-pve-storage-synology/?lang=zh#configure)。

## 探索工具

這個現在就能用，而且值得在其他任何事之前先跑一次。它是**唯讀**的：不建立、不刪除任何東西，跑完會自己登出。對正式機是安全的。

```bash
bin/pve-syno-api-probe --host 192.0.2.10 --user pve-storage
```

密碼會以關閉回顯的方式提示輸入——絕不從命令列傳入，那會在 `ps` 和 shell 歷史裡看得到。

它會回報 NAS 接受的 API 範圍與每一個版本區間、防 CSRF 是否開啟、DSM 儲存空間及其檔案系統、目前的 LUN 與 target、一顆既有 LUN 的 `dev_attribs`，最後給出一份登記簿：這次跑完解決了什麼、還有什麼需要寫入才能回答。

```
--probe-methods    探測哪些快照還原方法名稱存在
--otp <code>       用於開啟兩步驟驗證的帳號
--json             同時以 JSON 輸出結果
```

`--probe-methods` 需要明確開啟。它指名一個 NAS 從未發出過的 LUN 與快照 uuid，所以存在的方法只能拒絕——而拒絕本身就證明它在那裡。它能動到的東西並不存在，但送出的畢竟是破壞性方法的名稱，所以先問過再做。

## 清理工具

`pve-syno-reap` 會回報——加上 `--remove` 則清除——本節點為 NAS 上已不存在的 LUN 所持有的 multipath map，以及當機留下的追蹤記錄。**預設是試跑。**

```bash
pve-syno-reap --storage <storage>            # 顯示留下了什麼
pve-syno-reap --storage <storage> --remove   # 然後真的處理
pve-syno-reap --all --remove                 # 本節點上每一個 synologysan storage
```

**節點當機之後請執行它，移除 storage 之前也請在每個節點上執行**。有兩件事讓它成為必要，而兩件都是在三節點叢集上量測到的：

- Proxmox VE 在遷移過程中唯一的 `deactivate_volumes` 呼叫位於 `sync_offline_local_volumes` 裡面，所以對**共用** storage 而言，來源節點永遠不會被告知 VM 已經離開。一台 VM 從 `pve1 → pve2 → pve3` 遷移後在 pve3 上被銷毀，pve1 和 pve2 就會各自留著一個對應已不存在 LUN 的 map。
- 被硬重置的節點根本不會執行 `deactivate_volume`，所以它的追蹤檔會留著一筆對應「已不再掛載」LUN 的記錄。

兩者都不危險——每個使用者在動作之前都會重新檢查裝置，而裝置身分一律來自核心的 WWID——但它們會累積。這個工具絕不動到正在使用中的裝置，而且對任何無法確定狀態的東西是跳過，不是假設。

Proxmox VE 裡沒有任何東西會呼叫 `deactivate_storage`（對整個 `/usr/share/perl5/PVE` 目錄樹驗證過），所以這個清理工作屬於管理者，不屬於 PVE。

## 文件

| | |
|---|---|
| [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) | 哪些驗證過、哪些沒有，以及測試計畫。**在信任任何東西之前先讀這份** |
| [docs/LIMITS_zh-TW.md](docs/LIMITS_zh-TW.md) | 各機型公布的 LUN 與 target 上限，每個數字都附官方出處 |
| [docs/DSM-ACCOUNT_zh-TW.md](docs/DSM-ACCOUNT_zh-TW.md) | DSM 帳號、最小權限、自動封鎖、兩步驟驗證、TLS |

## 相關專案

其他陣列的 Proxmox VE 儲存 plugin，與本專案共用主機端的架構與它繼承的維運規則：

- [jt-pve-storage-dellemc](https://github.com/jasoncheng7115/jt-pve-storage-dellemc) —Dell EMC PowerStore、PowerVault ME、PowerFlex、Unity XT
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp) —NetApp ONTAP
- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage) —Pure Storage FlashArray

## 授權

MIT。見 [LICENSE](LICENSE)。

本專案與 Synology Inc. 無隸屬關係，也未經其背書。Synology 與 DSM 是 Synology Inc. 的商標。

## 作者

Jason Cheng (Jason Tools) &lt;jason@jason.tools&gt;
