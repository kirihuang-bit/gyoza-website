# Supabase Edge Functions(後端入口)

給網站呼叫的兩個後端入口。它們是資料庫函式的「守門員」:瀏覽器**不能**直接讀寫訂單表,
只能透過這兩個函式,由函式用 `service_role` 呼叫資料庫。

| 函式 | 用途 | 呼叫的資料庫函式 |
|---|---|---|
| `create-order` | 接收購物車送出的訂單 | `public.create_order(payload jsonb)` |
| `get-order` | 以訂單編號查詢訂單 | `public.track_order(p_order_no text)` |

依據檔案:`database/001_create_orders.sql`。**目前只有程式碼,尚未部署,也沒有實際執行或型別檢查過**
(本機沒有 Deno,我也沒有連線 Supabase)。請先在測試專案部署並用下面的範例測試。

## ⚠️ 先看這個:查詢只憑訂單編號

`get-order` **沒有驗證查詢者是誰,也沒有驗證訂單所有權**。任何知道(或猜到)訂單編號的人,
都能看到該訂單的品項、金額、狀態與時間。編號格式有規律(`JF` + 日期 + 當日流水號),可被推測;目前也**沒有流量限制**。

- 回傳內容已限制為 `track_order` 允許的欄位:**不含**姓名、手機、Email、地址、備註。
- 若要加強(例如「訂單編號 + 手機後三碼」),需要修改資料庫函式 `track_order` 並加上流量限制,這次沒有做。

## 1. `create-order`

**網址**:`https://<專案代號>.supabase.co/functions/v1/create-order`  **方法**:`POST`

### 接受的資料

`Content-Type` 可為 `application/json` 或 `text/plain`(現有前端用 `text/plain`),內容是 JSON:

```json
{
  "mode": "take",
  "name": "王小明",
  "phone": "0912345678",
  "email": "a@example.com",
  "store_id": "flag",
  "address": "",
  "note": "少辣",
  "hp": "",
  "items": [ { "id": "s1", "qty": 2 }, { "id": "p3", "qty": 1 } ]
}
```

| 欄位 | 必填 | 說明 |
|---|---|---|
| `mode` | 是 | `dine`(內用)/ `take`(外帶)/ `ship`(宅配) |
| `name`、`phone` | 是 | 手機須為 `09` 開頭共 10 碼(由資料庫檢查) |
| `email` | 否 | 有填才檢查格式 |
| `store_id` | 內用/外帶必填 | 門市代碼(`flag`、`xinyi`、`taichung`)。宅配會忽略 |
| `store` | 否(相容舊前端) | 舊前端送的下拉文字,如 `旗艦店 — 台北市…`。**只有沒給 `store_id` 時**才使用:取「 — 」前的名稱,到 `stores` 表(僅上架)查 id;查不到或不唯一就回 400「請選擇取餐門市」,不猜測 |
| `address` | 宅配必填 | |
| `note` | 否 | |
| `hp` | 否 | honeypot 欄位,正常請送空字串;有值會被當成機器人 |
| `items` | 是 | 1–30 項,每項 `{ "id": 商品代碼, "qty": 數量 }`;數量 1–50;同商品重複會合併 |

不認得的欄位會被丟棄;**前端送的金額、價格一律不採用**,金額由資料庫以商品價格重算。

### 回傳

成功 `200`(欄位為資料庫原樣回傳,另加 `orderNo` 別名,對應現有前端):

```json
{ "ok": true, "order_no": "JF261027-001", "total": 170, "eta": "約 15–20 分鐘", "orderNo": "JF261027-001" }
```

| HTTP | 內容 | 時機 |
|---|---|---|
| 200 | `{ "ok": true, ... }` | 成功。honeypot 有值時也回 200 與 `order_no: "JF-IGNORED"`,但**不會寫入訂單** |
| 400 | `{ "ok": false, "error": "…" }` | 輸入或業務驗證失敗,例如 `手機號碼格式不正確`、`請選擇取餐門市`、`部分商品已下架或不存在`、`商品數量不正確`、`購物車內容不正確`、`請求內容不是有效的 JSON`(`error` 可直接顯示給顧客) |
| 405 | `{ "ok": false, "error": "只接受 POST" }` | 不是 POST / OPTIONS |
| 413 | `{ "ok": false, "error": "請求內容過大" }` | 超過 32 KB |
| 500 | `{ "ok": false, "error": "系統忙碌中,請稍後再試" }` 或 `系統設定錯誤` | 資料庫或函式錯誤(詳細原因只寫在函式 Logs,不含個資) |

## 2. `get-order`

**網址**:`https://<專案代號>.supabase.co/functions/v1/get-order`  **方法**:`POST`

### 接受的資料

```json
{ "order_no": "JF261027-001" }
```

也接受現有前端的 `orderNo` 欄位名稱。大小寫不拘(資料庫會轉大寫)。

### 回傳

成功 `200`(資料庫原樣欄位 + `orderNo`、`statusLabel` 別名):

```json
{
  "ok": true,
  "order_no": "JF261027-001",
  "status": "new",
  "mode": "take",
  "createdAt": "2026-10-27T03:00:00.123+00:00",
  "updatedAt": "2026-10-27T03:00:00.123+00:00",
  "subtotal": 170, "fee": 0, "total": 170,
  "items": [ { "name": "招牌豬肉鍋貼 (10入)", "price": 85, "qty": 2 } ],
  "orderNo": "JF261027-001",
  "statusLabel": "新訂單"
}
```

- `status`:資料庫的英文狀態碼 `new / preparing / ready / delivering / done / cancelled`;`statusLabel` 是對應的中文(新訂單 / 製作中 / 待取餐 / 配送中 / 已完成 / 已取消)。
- 時間為帶時區的 ISO 字串(資料庫存 `timestamptz`),前端顯示時需自行轉成當地時間。

| HTTP | 內容 | 時機 |
|---|---|---|
| 400 | `{ "ok": false, "error": "訂單編號格式不正確(例:JF251022-001)" }` 等 | 缺少/格式錯誤的編號、不是有效 JSON |
| 404 | `{ "ok": false, "error": "查無此訂單" }` | 編號格式正確但不存在 |
| 405 / 413 / 500 | 同上表 | |

## 環境變數(Secrets)

| 名稱 | 誰提供 | 說明 |
|---|---|---|
| `SUPABASE_URL` | **Supabase 自動提供** | 不需要設定 |
| `SUPABASE_SERVICE_ROLE_KEY` | **Supabase 自動提供** | 後端金鑰,權限很大。只存在於函式執行環境,**絕不可放進前端或提交到 GitHub** |
| `ALLOWED_ORIGINS` | 你自己設定(選填) | 允許呼叫的網站來源,逗號分隔,例如 `https://你的帳號.github.io`。未設定時允許任何來源(`*`) |

> 自訂的 Secret 名稱不能以 `SUPABASE_` 開頭。`ALLOWED_ORIGINS` 只是限制「哪些網頁能用瀏覽器呼叫」,不是身分驗證;
> 它擋不住直接用工具(curl 等)發出的請求。

設定位置:Dashboard → **Edge Functions → Secrets**(或 Project Settings → Edge Functions)。

## 從 Dashboard 部署

1. 確認資料庫已執行 `database/001_create_orders.sql`,且 `stores`、`products` 內已有**上架**的資料(否則下單會被拒絕)。
2. Dashboard → **Edge Functions** → **Deploy a new function** → **Via Editor**。
3. 函式名稱填 `create-order`(必須完全一致,網址就是由名稱而來),把 `supabase/functions/create-order/index.ts` 的內容全部貼進編輯器,按 **Deploy**。
4. 同樣步驟再建立 `get-order`,貼上 `supabase/functions/get-order/index.ts`。
5. 每個函式的設定頁確認 **Verify JWT with legacy secret / Enforce JWT verification 為開啟**(預設就是開啟,請不要關閉)。
6. (選填)到 Secrets 新增 `ALLOWED_ORIGINS`。
7. 兩個檔案都是各自獨立的單一檔案,沒有共用模組,所以 Dashboard 編輯器可直接部署。

## 呼叫驗證設定與所需標頭

因為保留了 JWT 驗證,**每個請求都必須帶**:

| 標頭 | 值 |
|---|---|
| `Authorization` | `Bearer <你的 anon key>` |
| `apikey` | `<你的 anon key>` |
| `Content-Type` | `application/json`(或 `text/plain`) |

anon key 在 Dashboard → Project Settings → API(舊版 `eyJ…` 開頭的 anon / public key)。
它**是公開的**,放在前端沒問題;但也代表「帶得出這個 key」不等於「是真正的顧客」,安全性不靠它。
**`service_role` key 絕對不要放進前端。** 缺少標頭時,Supabase 會回 `401`,請求不會進到函式。

## 在 Dashboard 測試

Edge Functions → 點函式 → **Test** 分頁(標頭會自動帶上授權)。方法選 `POST`,貼上以下 Request Body。
測試範例假設資料表裡有門市 `flag`、商品 `s1`(85 元)且皆上架(`supabase/seed.sql` 草稿的資料);
若你的 Table Editor 測試資料不同,請換成實際存在的代碼,**金額預期值也要跟著算**。
⚠️ 下面「成功」的下單測試**會真的寫入一筆訂單**(這是正式資料表,請之後到 Table Editor 自行處理);失敗類測試不會寫入。

**測試 1:下單成功**(`create-order`)
```json
{ "mode": "take", "name": "測試客人", "phone": "0900000000", "store_id": "flag",
  "items": [ { "id": "s1", "qty": 2 } ] }
```
預期:HTTP 200,`ok: true`,`order_no` 形如 `JF261027-001`,`total` = 170。**記下這個編號供測試 6 使用。**

**測試 2:舊前端的 `store` 文字**(`create-order`,會寫入一筆)
```json
{ "mode": "take", "name": "測試客人", "phone": "0900000000", "store": "旗艦店 — 台北市中正區忠孝西路一段 100 號",
  "items": [ { "id": "s1", "qty": 1 } ] }
```
預期:HTTP 200,`total` = 85。

**測試 3:手機格式錯誤**(不會寫入)
```json
{ "mode": "take", "name": "測試客人", "phone": "123", "store_id": "flag",
  "items": [ { "id": "s1", "qty": 1 } ] }
```
預期:HTTP 400,`{"ok":false,"error":"手機號碼格式不正確"}`。

**測試 4:外帶沒選門市**(不會寫入)
```json
{ "mode": "take", "name": "測試客人", "phone": "0900000000", "items": [ { "id": "s1", "qty": 1 } ] }
```
預期:HTTP 400,`請選擇取餐門市`。

**測試 5:機器人欄位**(不會寫入)
```json
{ "hp": "bot", "mode": "take", "name": "x", "phone": "0900000000", "store_id": "flag",
  "items": [ { "id": "s1", "qty": 1 } ] }
```
預期:HTTP 200,`order_no` 為 `JF-IGNORED`,資料表沒有新訂單。

**測試 6:查單成功**(`get-order`)
```json
{ "order_no": "貼上測試 1 得到的編號" }
```
預期:HTTP 200,`status` 為 `new`、`statusLabel` 為 `新訂單`,`items` 有 1 項(數量 2),`total` 170,**回應裡沒有姓名、手機、備註**。

**測試 7:查單格式錯誤**(`get-order`)
```json
{ "order_no": "abc" }
```
預期:HTTP 400,`訂單編號格式不正確(例:JF251022-001)`。

**測試 8:查無此單**(`get-order`)
```json
{ "order_no": "JF000101-001" }
```
預期:HTTP 404,`{"ok":false,"error":"查無此訂單"}`。

**測試 9:CORS 預檢**(需用 curl 等工具,Dashboard Test 不方便)
```bash
curl -i -X OPTIONS "https://<專案代號>.supabase.co/functions/v1/create-order" \
  -H "Origin: https://example.com" -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: authorization, apikey, content-type"
```
預期:HTTP 204,回應標頭含 `Access-Control-Allow-Origin`(未設 `ALLOWED_ORIGINS` 時為 `*`)與 `Access-Control-Allow-Headers`。

## 與其他檔案的差異(只指出,未改動)

- `supabase/schema.sql`(先前的舊草稿)的 `create_order` / `track_order` 是 `security definer` 且**開放 anon 直接執行**;
  `database/001_create_orders.sql` 只給 `service_role`。函式名稱、參數與回傳格式相同。**本次以 `database/001` 為準**,請勿在同一個資料庫執行舊草稿。
- 我讀的是 SQL 檔案內容,不是線上資料庫的實際狀態;如果你在 Table Editor 或 SQL Editor 改過函式,請告訴我。

## 尚未完成

1. **前端還沒接**(`index.html` 未修改):仍然呼叫 Apps Script。接線時需要:改呼叫上面的網址並帶授權標頭;送 `store_id`(或維持現在的 `store` 文字,函式已相容);讀取回傳的 `orderNo`、`statusLabel`、`createdAt`/`updatedAt`(帶時區的 ISO 字串)。
2. **後台**(店員看單、改狀態)的 Edge Function 還沒有;`update_order_status` 已在資料庫,但沒有對外入口。
3. **通知信**、流量限制、更強的查單驗證(見上方「先看這個」)尚未處理。
4. 兩個函式尚未部署,也尚未做過任何實際執行或型別檢查。
