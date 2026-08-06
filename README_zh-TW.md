# jt-pve-storage-synology

透過 iSCSI 連接 Synology NAS 的 Proxmox VE 儲存 plugin。**一顆 VM 磁碟就是 NAS 上一個精簡配置 LUN**，所以 DSM 自己的快照、複本與容量都作用在操作者心裡想的那個單位上——沒有 LVM 夾層，也不把一個共用 LUN 在本機切開。

[English](README.md) · [繁體中文](README_zh-TW.md)

---

> ### 狀態：模組層已經可以用。**PVE plugin 本身還沒有寫。**
>
> `synologyiscsi` 還不能加到節點上。程式庫現在有的是 plugin 底下那一層：`Synology::API`、`::LUN`、`::Target`、`::Naming`、`::Multipath`、`::Command`，附單元測試，以及一次對著實機跑完的建立／快照／倒回／複製／對應／刪除完整生命週期——外加 `bin/pve-syno-api-probe`，一個唯讀工具，用來問一台 DSM 它實際上支援什麼。
>
> 在這個階段就公開，是因為探索工具本身就有用；也因為在任何人信任一個建立在 Synology SAN API 上的 plugin 之前，那份「哪些知道、哪些不知道」的誠實登記簿值得先讀一遍。
>
> **現在不要把正式資料放上來。** 現在也還沒有東西可以放。

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
| LUN 的 uuid 不可以變 | **它不會變。** 所以 SCSI 序號與 WWID 都存活，節點不會突然在自己磁碟的位置上找到另一顆 |
| 比還原點更新的快照必須存活 | **會存活。** 還原到三個之中最舊的那一個，三個都還在 |
| 事後必須看得出來 | `restored_time` 會記錄還原當下的 epoch 秒 |

第二件正是相關專案**拒絕**越過較新快照倒回的原因：在那些陣列上較新的快照會被銷毀，所以讓 PVE 默默做那件事的 plugin，等於刪掉使用者還看得到的快照。這裡什麼都不會被銷毀，所以那道限制不需要，一顆磁碟也可以反覆倒回。

## 需求

| | |
|---|---|
| DSM | **7.0 以上**，而且只驗證過 7.1.1。雙控制器的 DSM UC 會被**拒絕**，不會假裝支援。見下——版本號只是門檻，不是判準 |
| 儲存空間 | **Btrfs。** 快照只存在於 Btrfs 上的精簡 LUN——ext4 的儲存空間在加入 storage 時就被拒絕，而不是等到第一次拍快照才失敗 |
| 型號 | 支援 iSCSI target 且有足夠可用空間者。產品上限是每台 512 個 LUN、256 個 target |
| 網路 | 以 HTTPS 連到 DSM（5001）。純 HTTP 一律拒絕 |
| 帳號 | 一個專用的 DSM 帳號——見 **[docs/DSM-ACCOUNT_zh-TW.md](docs/DSM-ACCOUNT_zh-TW.md)**，其中也說明了 DSM 唯一不讓你限制的那件事 |
| PVE | 8.x／9.x。儲存 API 版本是協商出來的，從不寫死 |

### DSM 版本只是門檻，不是判準

**要求 7.0 以上。** 技術下限其實更低——Cinder 的 driver 一路支援到 DSM 6.0.2，而 Btrfs 精簡 LUN 的快照從 6.2 就有——所以 7.0 是刻意選的保守值，理由有四個：SAN Manager 是 7.0 才有的產品，6.x 是 iSCSI Manager；本 plugin 需要的存取控制物件只在 7.x 上見過；**Synology 自己的 CSI driver 就要求 7.0 以上**，那是 Synology 自己會拿 API 用戶端去實際跑的範圍；而 DSM 6.2 已經 EOL，不管 API 通不通，拿它跑生產儲存都不該被建議。

真正驗證過的只有 **7.1.1-42962 Update 9**。7.0 到那之間應該可以用，但沒試過。

**但版本檢查通過不代表這台 NAS 能用**，而這件事比那個數字重要：

| 真正決定的東西 | 為什麼它比版本號可靠 |
|---|---|
| `SYNO.Core.System` 的 `support_iscsi_target`、`supportsnapshot`、`support_storage_mgr` | 這些描述的是**機型**，不是 OS 版本 |
| `SYNO.API.Info` 有沒有公佈需要的 API | 測試機跑 7.1.1，卻完全沒有 NVMe-oF 的 API。沒有任何版本號看得出這件事 |
| 儲存空間是不是 **Btrfs** | 比 DSM 版本更嚴的限制：**Btrfs 支援是看機型的**，沒有 Btrfs 的入門機不管哪一版 DSM 都拍不出快照 |

所以一台跑 7.2 的入門機仍然可能不能用，而只讀版本號的檢查不會說出原因。plugin 會四項全查，並指出是哪一項不過。

## 高可用性與雙控制器

Synology 有兩種都被叫做「HA」的架構，但它們是兩個不同的問題、有不同的答案。**兩種都支援。**

| | **Synology HA（SHA）** | **UC／SA 雙控制器** |
|---|---|---|
| 架構 | 兩台機箱，主／備 | 一個機箱兩個控制器 |
| 偵測方式 | — | `firmware_ver` 含 `DSM UC` |
| 管理位址 | **一個浮動的叢集 IP** | **每個控制器各一個，沒有浮動位址** |
| 設定方式 | `--syno-portal <叢集 IP>` | `--syno-portal <控制器 A>,<控制器 B>` |
| 最接近的類比 | Pure Storage 的 `vir0` | PowerVault ME 的兩個控制器位址 |

`syno-portal` 收一份清單，依序嘗試、失敗就輪替。輪替發生在登入**裡面**，而請求的 URL 是在輪替之後才組——相關專案出過一個缺陷：URL 先組好了，所以每次重試都繼續送往剛剛才被判定死掉的那個位址。

UC 機箱的第二個位址不必手動設定：`SYNO.Core.Network.Interface` 接受 `relay_node=node0` 與 `node1`，可以列舉對側控制器的介面。在單控制器的 NAS 上兩者回傳相同的介面，所以這個機制在不需要它的地方是無害的。那些機型上，target 的 `network_portals` 還會帶 `controller_id`，而單控制器的 NAS 完全不回傳這個欄位。

### 兩種都沒有在實機上跑過，而 plugin 會說出這件事

SHA 風險低：它就是一個會移動的位址，而那正是 plugin 已經處理的情況。UC 是真正的未知，而未解的問題正是只有機箱能回答的——一顆 LUN 是否由單一控制器擁有、target 的 portal 是否依控制器而不同。這兩件合起來決定故障切換之後節點還找不找得到自己的磁碟。

所以 plugin 偵測到 `DSM UC` 時**發出警告**而不是拒絕，而這一頁會一直寫著「未驗證」，直到有人回報實際運行結果。兩者在登記簿上是 R-15 與 R-16。

**如果你手上有其中任何一種，最有價值的回報是一個數字**：`SYNO.Core.ISCSI.Node` 的 uuid 在故障切換之後還是同一個嗎？storage 的身分釘在它上面，所以如果它會變，那道釘子就不再保護 storage，而是開始破壞它。

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

## 文件

| | |
|---|---|
| [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) | 哪些驗證過、哪些沒有，以及測試計畫。**在信任任何東西之前先讀這份** |
| [docs/DSM-ACCOUNT_zh-TW.md](docs/DSM-ACCOUNT_zh-TW.md) | DSM 帳號、最小權限、自動封鎖、兩步驟驗證、TLS |

## 相關專案

其他陣列的 Proxmox VE 儲存 plugin，與本專案共用主機端的架構與它繼承的維運規則：

- [jt-pve-storage-dellemc](https://github.com/jasoncheng7115/jt-pve-storage-dellemc) — Dell EMC PowerStore、PowerVault ME、PowerFlex、Unity XT
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp) — NetApp ONTAP
- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage) — Pure Storage FlashArray

## 授權

MIT。見 [LICENSE](LICENSE)。

本專案與 Synology Inc. 無隸屬關係，也未經其背書。Synology 與 DSM 是 Synology Inc. 的商標。

## 作者

Jason Cheng (Jason Tools) &lt;jason@jason.tools&gt;
