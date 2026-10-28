-- 舊資料遷移草稿(Google Sheet → Supabase)。尚未執行。
-- 前提:schema.sql、seed.sql 已執行。
-- 步驟:
--   1. 試算表「訂單」「訂單明細」各匯出 CSV(「手機」欄請先確認仍保有開頭 0)。
--   2. 在 Supabase 以 Table Editor 匯入到下面兩個暫存表(全部欄位用 text,避免自動轉型)。
--   3. 執行本檔的 INSERT;檢查結果後刪除暫存表。
-- 假設(待確認):試算表時區 = Asia/Taipei;舊單 N 欄「更新時間」為空 → 以建立時間補。

create table public.import_orders (
  order_no text, created_at text, status text, mode text, name text, phone text, email text,
  store text, address text, note text, subtotal text, fee text, total text, updated_at text
);
create table public.import_items (
  order_no text, product_id text, product_name text, unit_price text, qty text, line_total text
);

-- 1) 訂單
insert into public.orders (order_no, status, fulfillment_type, customer_name, customer_phone, customer_email,
                           store_id, ship_address, note, subtotal, fee, total, created_at, updated_at)
select
  btrim(o.order_no),
  case btrim(o.status) when '新訂單' then 'new' when '製作中' then 'preparing' when '待取餐' then 'ready'
                       when '配送中' then 'delivering' when '已完成' then 'done' when '已取消' then 'cancelled' end,
  case btrim(o.mode) when '內用' then 'dine' when '外帶' then 'take' when '宅配' then 'ship' end,
  btrim(o.name),
  btrim(o.phone),
  nullif(btrim(o.email), ''),
  (select s.id from public.stores s where s.name = btrim(split_part(o.store, ' — ', 1)) limit 1),  -- 兩種舊格式皆適用
  nullif(btrim(o.address), ''),
  nullif(btrim(o.note), ''),
  o.subtotal::integer, o.fee::integer, o.total::integer,
  (o.created_at::timestamp) at time zone 'Asia/Taipei',
  coalesce(nullif(btrim(o.updated_at), '')::timestamp, o.created_at::timestamp) at time zone 'Asia/Taipei'
from public.import_orders o;
-- 若狀態/取餐方式出現上述以外的值,該欄會是 null 並觸發 not null / check 錯誤,整批回滾 → 先修正來源資料。

-- 2) 明細(同單同商品重複者合併;商品已不存在則 product_id 設為 null,仍保留品名與單價快照)
insert into public.order_items (order_id, product_id, product_name, unit_price, quantity, line_total)
select o.id,
       (select p.id from public.products p where p.id = btrim(i.product_id)),
       i.product_name, i.unit_price::integer, sum(i.qty::numeric)::integer,
       i.unit_price::integer * sum(i.qty::numeric)::integer
from public.import_items i
join public.orders o on o.order_no = btrim(i.order_no)
group by o.id, i.product_id, i.product_name, i.unit_price;

-- 3) 每日流水號計數器接續(避免新單與舊編號重複)
insert into public.order_counters (day, last_seq)
select to_date(substr(order_no, 3, 6), 'YYMMDD'), max(split_part(order_no, '-', 2)::integer)
from public.orders where order_no ~ '^JF[0-9]{6}-[0-9]+$'
group by 1
on conflict (day) do update set last_seq = greatest(order_counters.last_seq, excluded.last_seq);

-- 4) 檢查(請人工確認)
-- select count(*) from public.import_orders;  select count(*) from public.orders;
-- select order_no from public.orders o where not exists (select 1 from public.order_items i where i.order_id = o.id);   -- 沒有明細的訂單
-- select o.order_no from public.orders o where o.fulfillment_type <> 'ship' and o.store_id is null;                   -- 對不到門市
-- select o.order_no from public.orders o join public.order_items i on i.order_id = o.id group by o.id, o.order_no, o.subtotal
--   having sum(i.line_total) <> o.subtotal;                                                                           -- 小計與明細不符
-- drop table public.import_orders, public.import_items;
