# jt-pve-storage-synology

透過 iSCSI 連接 Synology NAS 的 Proxmox VE 儲存 plugin。**一顆 VM 磁碟就是 NAS 上
一個精簡配置 LUN**，所以 DSM 自己的快照、複本與容量都作用在操作者心裡想的那個單位
上——沒有 LVM 夾層，也不把一個共用 LUN 在本機切開。

[English](README.md) · [繁體中文](README_zh-TW.md)

---

> ### 狀態：規格與探索階段。**還沒有 plugin。**
>
> 這個程式庫目前包含開發規格、專案規則，以及 `bin/pve-syno-api-probe`——一個唯讀
> 工具，用來問一台 DSM 它實際上支援什麼。plugin 本身還沒有寫。
>
> 在這個階段就公開，是因為探索工具本身就有用；也因為在任何人信任一個建立在
> Synology SAN API 上的 plugin 之前，那份「哪些知道、哪些不知道」的誠實登記簿值得
> 先讀一遍。
>
> **現在不要把正式資料放上來。** 現在也還沒有東西可以放。

---

## 為什麼有這個專案，以及麻煩在哪裡

Synology 沒有公開 SAN Manager Web API 的規格。唯一的官方文件——DSM Login Web API
Guide——只涵蓋登入與 API 探索，完全沒有記載任何 LUN、target、對應或快照的呼叫。

真正存在的是兩份在生產環境和它對話的獨立實作：

- **Synology 官方的 CSI driver**，[SynologyOpenSource/synology-csi](https://github.com/SynologyOpenSource/synology-csi)（Apache-2.0）
- **OpenStack Cinder 內建的 Synology driver**，在 [Cinder](https://github.com/openstack/cinder) 的原始碼樹裡（Apache-2.0）

這個專案的事實來自**把這兩份互相對讀**，然後再去問實機。最後那一步很重要：兩份的
做法有出入，而只要有出入，在任一台特定的 DSM 上至少有一份是錯的。在用來測試的
DSM 7.1.1 上，**Cinder 帶工作階段的方式完全不能用**，而在開啟防 CSRF 的 DSM 上
**兩份都沒有送 NAS 要求的那個 token**。

凡是無法確認的地方，這個 plugin **拒絕該操作**，而不是猜。`docs/TESTING_zh-TW.md`
就是那份登記簿，而且它會被誠實地維護。

從那兩個專案取用的只有協定事實——API 名稱、方法名稱、參數、錯誤碼。沒有任何程式碼
衍生自它們；本專案是 Perl，結構是自己的。

## 它將會做的事

| PVE 操作 | 在 NAS 上 |
|---|---|
| 建立磁碟 | 在 Btrfs 儲存空間上建立精簡（`BLUN`）LUN，並開啟 `can_snapshot` 與 UNMAP |
| 刪除磁碟 | 先解除對應再刪除，並且先刪掉它自己的快照 |
| 擴充磁碟 | LUN 擴充，然後在每個節點做有界的逐裝置刷新 |
| 快照 | DSM 的 LUN 快照，並加上標記，絕不與使用者自己的快照混淆 |
| 複製 | 從 LUN 或它的某個快照複製 |
| **倒回** | **第一版拒絕**——理由見下 |
| 掛上／卸離 | iSCSI 登入，裝置由核心自己的識別找出，dm-multipath |

### 為什麼倒回被拒絕

兩份參考實作都沒有這個功能：Kubernetes 與 Cinder 都是用「把快照複製成一個**新的**
volume」來還原，所以兩者都不需要它。SAN Manager 的介面上明明有「還原」按鈕，而 NAS
在每一顆 LUN 上都會回報 `restored_time` 欄位，所以 API 確實存在——但**它的方法名稱
未知**，而這個專案不會拿猜來的名稱去做破壞性操作。

有些 plugin 採用的替代方案——複製快照、刪掉原本的、把複本改成它的名字——在這裡不
被接受。它在替代品被證明之前就毀掉了原件，而且它改變了 LUN 的身分，所以每個節點看到
的都是另一顆磁碟。

快照的建立、列出、刪除都可用，所以 `vzdump` 的快照模式沒有問題。
`bin/pve-syno-api-probe --probe-methods` 存在的目的就是解除這個限制，而它是一位
Synology NAS 的擁有者能為這個專案做的最有價值的一件事。

## 需求

| | |
|---|---|
| DSM | 7.x。雙控制器的 DSM UC 會被**拒絕**，不會假裝支援 |
| 儲存空間 | **Btrfs。** 快照只存在於 Btrfs 上的精簡 LUN——ext4 的儲存空間在加入 storage 時就被拒絕，而不是等到第一次拍快照才失敗 |
| 型號 | 支援 iSCSI target 且有足夠可用空間者。產品上限是每台 512 個 LUN、256 個 target |
| 網路 | 以 HTTPS 連到 DSM（5001）。純 HTTP 一律拒絕 |
| 帳號 | 一個專用的 DSM 帳號——見 **[docs/DSM-ACCOUNT_zh-TW.md](docs/DSM-ACCOUNT_zh-TW.md)**，其中也說明了 DSM 唯一不讓你限制的那件事 |
| PVE | 8.x／9.x。儲存 API 版本是協商出來的，從不寫死 |

## 探索工具

這個現在就能用，而且值得在其他任何事之前先跑一次。它是**唯讀**的：不建立、不刪除
任何東西，跑完會自己登出。對正式機是安全的。

```bash
bin/pve-syno-api-probe --host 192.0.2.10 --user pve-storage
```

密碼會以關閉回顯的方式提示輸入——絕不從命令列傳入，那會在 `ps` 和 shell 歷史裡
看得到。

它會回報 NAS 接受的 API 範圍與每一個版本區間、防 CSRF 是否開啟、DSM 儲存空間及其
檔案系統、目前的 LUN 與 target、一顆既有 LUN 的 `dev_attribs`，最後給出一份登記簿：
這次跑完解決了什麼、還有什麼需要寫入才能回答。

```
--probe-methods    探測哪些快照還原方法名稱存在
--otp <code>       用於開啟兩步驟驗證的帳號
--json             同時以 JSON 輸出結果
```

`--probe-methods` 需要明確開啟。它指名一個 NAS 從未發出過的 LUN 與快照 uuid，所以
存在的方法只能拒絕——而拒絕本身就證明它在那裡。它能作用的對象並不存在，但送出的畢竟
是破壞性方法的名稱，所以先問過再做。

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

本專案與 Synology Inc. 無隸屬關係，也未經其背書。Synology 與 DSM 是 Synology Inc.
的商標。
