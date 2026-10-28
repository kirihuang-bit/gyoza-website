# 資料庫(Supabase PostgreSQL)

這個資料夾是「Google Apps Script + Google Sheet」改接 Supabase 的**資料庫部分**。
目前**只有 SQL 檔案**,還沒有在任何 Supabase 專案執行過,網站與 Apps Script 也完全沒有改動。

## 架構與安全原則

```
訪客的瀏覽器 ──► Supabase Edge Functions(使用 service_role)──► 資料庫
        └──(僅讀取)anon key ──► products / stores(只看得到上架資料)
```

- 訪客**不能**直接讀寫訂單相關資料表。訂單、明細、狀態紀錄、計數器、店員名單都啟用 RLS 且**沒有任何政策**,
  並且明確收回 anon / authenticated 的所有權限。
- 只有 Edge Function 用 **service_role** 讀寫,而且 service_role 也只被授與必要權限(**沒有 DELETE / TRUNCATE**)。
- 下單、查單、改狀態是三個資料庫函式,**只有 service_role 能執行**。
- ⚠️ service_role / secret key **只能放在 Edge Function 的環境變數**,絕對不要寫進 `index.html`、`admin.html` 或任何前端檔案。
  前端只能用 anon(publishable)key,而且它只能讀商品與門市。

## 檔案與執行順序

| 順序 | 檔案 | 用途 |
|---|---|---|
| 1 | `001_create_orders.sql` | 建立資料表、限制、索引、函式、觸發器,並設定 RLS 與權限 |
| 2 | `002_verify_orders.sql` | 檢查結構與權限,並用虛構訂單測試下單、查單、改狀態;全程自動回滾 |
| — | `README.md` | 本說明 |

在 Supabase Dashboard → **SQL Editor** 貼上整份檔案後執行(請用預設的 postgres 身分)。**先 001,再 002。**

> 001 可以重複執行(只用 `create ... if not exists` / `create or replace`,觸發器與政策是先 drop 再重建),
> 不使用 DROP TABLE、TRUNCATE,也不會刪除任何資料列。

## 每一步預期看到什麼

**執行 001**:最後顯示 *Success. No rows returned*,沒有錯誤。
之後在 Table Editor 應看到 7 張表:`stores`、`products`、`orders`、`order_items`、`order_status_log`、`order_counters`、`staff_members`,
且每張表都標示 RLS enabled。

**執行 002**:SQL Editor 會顯示**一則錯誤訊息,這是刻意設計**——測試最後用「拋出錯誤」來強制整個交易回滾,
確保不會留下任何假訂單。錯誤訊息的內容就是驗證報告:

```
VERIFY_OK — 通過 N / 失敗 0 / 略過 0(此「錯誤」是刻意的:…)
[PASS] 資料表存在:stores
[PASS] RLS 已啟用:stores
...
```

- 第一行是 `VERIFY_OK` 且「失敗 0」才算通過。若是 `VERIFY_FAILED`,往下找 `[FAIL]` 的那幾行,把整份報告貼給我即可。
- `[SKIP]` 只會出現在「無法在你的環境建立虛構店員」時(會略過後台改狀態的測試),不代表其他測試有問題。
- 測試會用到的虛構資料(門市 `zz_test_store`、商品 `zz_test_p1/p2/off`、店員、訂單)都在同一個交易內,結束後不會保留;
  也不會動到你既有的資料。想再確認可另外執行(三個結果都應為 0):

```sql
select count(*) from public.orders   where customer_name like 'ZZ%';
select count(*) from public.products where id like 'zz_test_%';
select count(*) from public.stores   where id like 'zz_test_%';
```

## 哪些來自原專案,哪些是這次新增

### 來自原專案(`gas/Code.gs`、`index.html`)

| 項目 | 來源 |
|---|---|
| 訂單欄位:訂單編號、建立時間、狀態、取餐方式、姓名、手機、Email、門市、地址、備註、小計、運費/服務費、應付總額、更新時間 | 「訂單」工作表 14 欄 |
| 明細欄位:商品ID、品名、單價、數量、小計(品名與單價為下單當下快照) | 「訂單明細」工作表 |
| 商品欄位:ID、品名、單價、分類、上架 | 「商品」工作表 |
| 驗證規則:手機 `09` 開頭共 10 碼、Email 格式、姓名必填、宅配必填地址、1–30 個品項、每項 1–50 份、文字截 200 字、清除控制字元 | `validate_`、`price_` |
| 費用規則:內用 10%(四捨五入)、外帶 0、宅配滿 1000 免運否則 150 | `FEES` |
| 金額以資料庫商品價格重算,不信任前端 | `price_` |
| 訂單編號格式 `JF` + `yyMMdd` + 流水號 | `nextOrderNo_` |
| honeypot 欄位:機器人靜默略過 | `doPost` |
| 查單只憑訂單編號,不回傳個資 | `track_` |
| 狀態共六種(新訂單、製作中、待取餐、配送中、已完成、已取消) | `CONFIG.STATUSES` |
| 預計時間文字(15–20 分鐘 / 2–3 個工作天) | `FEES[..].eta` |

### 這次新增或改變

| 項目 | 說明 |
|---|---|
| `id uuid` 主鍵 + 唯一 `order_no` | 原本訂單編號就是識別,現在 uuid 為主鍵、`order_no` 為顯示用且唯一 |
| 狀態改英文代碼 | `new / preparing / ready / delivering / done / cancelled`,畫面再轉成中文 |
| 取餐方式改代碼 | `dine / take / ship`(前端本來就送這三個值) |
| `stores` 表、`store_id` | 原本訂單存「旗艦店 — 地址」整串文字,現在存門市代碼 |
| `products` 表加入圖片、描述、標籤、排序等 | 原本只有價格在 Sheet,其餘寫死在前端 |
| `order_status_log` 狀態紀錄 | 原本只有最後狀態;現在記錄每次變更(誰、何時、從哪到哪) |
| `order_counters` 每日計數器 | 原本存在 Apps Script 的 Script Properties;並修正「第 1000 筆會重複」的問題 |
| `staff_members` 店員名單 | 取代 `ADMIN_KEY`;後台 Edge Function 以此判斷是否為店員 |
| `updated_at` 自動更新(觸發器) | 原本靠程式手動寫入 |
| 時間改為 `timestamptz`,編號日期固定用台北時間 | 原本 Sheet 時間不含時區 |
| 同一商品重複出現時合併成一列 | 原本會變成兩列 |
| 內用 / 外帶必須選門市 | 原本後端沒有強制;資料表本身仍允許 `store_id` 為空,以便遷移舊資料 |
| 資料庫層的 CHECK 限制(`total = subtotal + fee` 等)、RLS 與函式權限 | 全新 |

## 這次尚未完成的串接工作

1. **Edge Functions 還沒寫**:下單(呼叫 `create_order`)、查單(`track_order`)、後台列表與改狀態(驗證 Supabase Auth 登入者是店員後呼叫 `update_order_status`)、honeypot 與流量限制。
2. **前端還沒改**:`index.html`、`admin.html` 仍然連 Apps Script;需改為呼叫 Edge Functions,並把門市與商品改從 Supabase 讀取。查單回傳的狀態是英文代碼,前端要轉回中文。
3. **商品與門市種子資料還沒匯入**:`supabase/seed.sql` 是先前產生的草稿(尚未執行);表建好之後 `products`、`stores` 是空的,前端與下單都需要有資料。
4. **舊資料遷移還沒做**:`supabase/migrate_from_sheet.sql` 是草稿(尚未執行);需先確認試算表時區(目前假設 Asia/Taipei)。
5. **通知信**(店家收單通知、顧客確認信)尚未決定如何取代 `notify_`。
6. **店員帳號流程**:需先在 Supabase Authentication 建立店員帳號,再把對應 user id 加進 `staff_members`(目前沒有自動化流程)。
7. 實際執行 `001` / `002` 前,我沒有在任何 PostgreSQL 上跑過這兩個檔案(本機沒有可用的 Postgres 或 Docker 服務),請先在你的 Supabase 專案(建議先用測試專案)執行並回報 `002` 的報告。
8. `supabase/schema.sql` 是先前的草稿(RPC 開放給 anon),已被本資料夾取代,**請以 `database/` 為準**。
