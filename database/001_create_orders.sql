-- ============================================================================
-- 001_create_orders.sql — 煎福鍋貼 · Supabase 資料表建立
--
-- 架構:網站 →(Edge Function,使用 service_role)→ 本資料庫。
--       訪客(anon)與一般登入者(authenticated)不能直接讀寫任何訂單資料。
--
-- 安全提醒:service_role / secret key 只能放在 Edge Function 的環境變數,
--           絕對不可寫進 index.html、admin.html 或任何前端檔案。
--
-- 本檔可重複執行:只使用 create ... if not exists / create or replace,
-- 觸發器與政策以 drop ... if exists 後重建;不使用 DROP TABLE、TRUNCATE,不刪除任何資料列。
-- 來源對照:gas/Code.gs 的「訂單」「訂單明細」「商品」工作表、doPost、track_、admin_。
-- ============================================================================

create extension if not exists pgcrypto;

-- ============================================================================
-- 1. 資料表
-- ============================================================================

-- 門市(原:前端 index.html 的 STORES 寫死;訂單原本只存「名稱 — 地址」文字)
create table if not exists public.stores (
  id          text primary key,                    -- flag / xinyi / taichung
  name        text not null,
  address     text not null,
  phone       text,
  sort_order  integer not null default 0,
  is_active   boolean not null default true
);

-- 商品(原:「商品」工作表 + 前端 MENU / GIFTS)。金額一律以此表為準。
create table if not exists public.products (
  id              text primary key,                -- s1 d1 p1 k1 g1 ...(原「商品ID」)
  name            text not null,                   -- 原「品名」
  price           integer not null check (price >= 0),  -- 原「單價」,整數新台幣
  category_key    text not null,                   -- signature / dumpling / soup / side / gift(前端 MENU 的 key)
  category_label  text not null,                   -- 原「分類」
  description     text,
  image_url       text,
  tags            text[] not null default '{}',
  sub_label       text,                            -- 禮盒副標(GIFTS.sub)
  badge           text,                            -- 禮盒徽章(GIFTS.badge)
  sort_order      integer not null default 0,
  is_active       boolean not null default true    -- 原「上架(TRUE/FALSE)」
);

-- 訂單主檔(原:「訂單」工作表,每單一列)
create table if not exists public.orders (
  id                uuid primary key default gen_random_uuid(),          -- 新增
  order_no          text not null unique,                                -- 原「訂單編號」JF251022-001
  status            text not null default 'new'                          -- 原「狀態」(中文)→ 英文代碼
                      check (status in ('new','preparing','ready','delivering','done','cancelled')),
  fulfillment_type  text not null check (fulfillment_type in ('dine','take','ship')),  -- 原「取餐方式」(中文)→ 代碼
  customer_name     text not null check (length(btrim(customer_name)) > 0),
  customer_phone    text not null check (customer_phone ~ '^09[0-9]{8}$'),
  customer_email    text check (customer_email is null or customer_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  store_id          text references public.stores(id),                   -- 原「門市」整串文字 → 門市代碼
  ship_address      text,
  note              text,
  subtotal          integer not null check (subtotal >= 0),
  fee               integer not null default 0 check (fee >= 0),         -- 原「運費/服務費」
  total             integer not null check (total >= 0),
  created_at        timestamptz not null default now(),                  -- 原「建立時間」(原本不含時區)
  updated_at        timestamptz not null default now(),                  -- 原「更新時間」(本專案後來才加的第 14 欄)
  constraint orders_total_ok  check (total = subtotal + fee),
  constraint orders_ship_addr check (fulfillment_type <> 'ship' or length(btrim(coalesce(ship_address, ''))) > 0)
  -- store_id 不加 not null:舊系統內用/外帶未強制選門市,為了能遷移舊資料;新單由 create_order() 要求必填。
);
create index if not exists orders_created_at_idx on public.orders (created_at desc);
create index if not exists orders_status_idx     on public.orders (status);

-- 訂單明細(原:「訂單明細」工作表,每個品項一列;品名、單價為下單當下快照)
create table if not exists public.order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders(id) on delete cascade,
  product_id    text references public.products(id) on delete set null,   -- 原「商品ID」
  product_name  text not null,                                            -- 原「品名」
  unit_price    integer not null check (unit_price >= 0),                 -- 原「單價」
  quantity      integer not null check (quantity between 1 and 50),       -- 原「數量」(上限同 MAX_QTY_PER_ITEM)
  line_total    integer not null check (line_total = unit_price * quantity)  -- 原「小計」
);
create index if not exists order_items_order_idx on public.order_items (order_id);

-- 狀態變更紀錄(新增:原系統只存最後狀態)
create table if not exists public.order_status_log (
  id           bigint generated always as identity primary key,
  order_id     uuid not null references public.orders(id) on delete cascade,
  from_status  text,
  to_status    text not null,
  changed_by   uuid,                                -- 操作的店員(auth.users.id);顧客下單為 null
  changed_at   timestamptz not null default now()
);
create index if not exists order_status_log_order_idx on public.order_status_log (order_id, changed_at);

-- 每日訂單流水號(新增:原本存在 Apps Script 的 Script Properties「seq_yyMMdd」)
create table if not exists public.order_counters (
  day       date primary key,                       -- 台北時間的日期
  last_seq  integer not null
);

-- 店員名單(新增:取代原本的 ADMIN_KEY;後台 Edge Function 以此判斷是否為店員)
create table if not exists public.staff_members (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  display_name  text
);

-- ============================================================================
-- 2. 函式
-- ============================================================================

-- 費用規則(原 Code.gs 的 FEES:內用 10% 四捨五入、外帶 0、宅配滿 1000 免運否則 150)
create or replace function public.calc_fee(p_mode text, p_subtotal integer)
returns integer language sql immutable set search_path = public as $$
  select case p_mode
    when 'dine' then round(p_subtotal * 0.1)::integer
    when 'take' then 0
    when 'ship' then case when p_subtotal >= 1000 then 0 else 150 end
  end
$$;

-- 是否為店員
create or replace function public.is_staff(p_user uuid)
returns boolean language sql stable set search_path = public as $$
  select exists (select 1 from public.staff_members where user_id = p_user)
$$;

-- 訂單編號:JF + yyMMdd(台北時間)+ 流水號(不足 3 位補 0;超過 999 不截斷,修正原系統第 1000 筆會重複的問題)
create or replace function public.next_order_no()
returns text language plpgsql set search_path = public as $$
declare
  v_day date := (now() at time zone 'Asia/Taipei')::date;
  v_seq integer;
begin
  insert into public.order_counters (day, last_seq) values (v_day, 1)
  on conflict (day) do update set last_seq = public.order_counters.last_seq + 1
  returning last_seq into v_seq;
  return 'JF' || to_char(v_day, 'YYMMDD') || '-' ||
         case when v_seq < 1000 then lpad(v_seq::text, 3, '0') else v_seq::text end;
end $$;

-- 下單(取代 Apps Script doPost):驗證 → 以商品表重算金額 → 產編號 → 同一交易寫主檔與明細。
-- 輸入 payload:{ mode, name, phone, email, store_id, address, note, hp, items:[{id, qty}] }
create or replace function public.create_order(payload jsonb)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_mode     text := payload->>'mode';
  v_name     text := left(btrim(regexp_replace(coalesce(payload->>'name',    ''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_phone    text := left(btrim(regexp_replace(coalesce(payload->>'phone',   ''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_email    text := left(btrim(regexp_replace(coalesce(payload->>'email',   ''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_addr     text := left(btrim(regexp_replace(coalesce(payload->>'address', ''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_note     text := left(btrim(regexp_replace(coalesce(payload->>'note',    ''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_store    text := nullif(btrim(coalesce(payload->>'store_id', '')), '');
  v_lines    jsonb;
  v_n_valid  integer;
  v_n_lines  integer;
  v_n_found  integer;
  v_sub      integer;
  v_fee      integer;
  v_order_no text;
  v_id       uuid;
begin
  -- honeypot:機器人靜默略過(與原系統行為一致),不寫入任何資料
  if coalesce(payload->>'hp', '') <> '' then
    return jsonb_build_object('ok', true, 'order_no', 'JF-IGNORED');
  end if;

  if v_mode is null or v_mode not in ('dine', 'take', 'ship') then
    return jsonb_build_object('ok', false, 'error', '取餐方式不正確');
  end if;
  if v_name = '' then
    return jsonb_build_object('ok', false, 'error', '請填寫姓名');
  end if;
  if v_phone !~ '^09[0-9]{8}$' then
    return jsonb_build_object('ok', false, 'error', '手機號碼格式不正確');
  end if;
  if v_email <> '' and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    return jsonb_build_object('ok', false, 'error', 'Email 格式不正確');
  end if;

  if v_mode = 'ship' then
    if v_addr = '' then
      return jsonb_build_object('ok', false, 'error', '宅配需填寫地址');
    end if;
    v_store := null;
  else
    v_addr := null;
    if v_store is null or not exists (select 1 from public.stores where id = v_store and is_active) then
      return jsonb_build_object('ok', false, 'error', '請選擇取餐門市');
    end if;
  end if;

  if jsonb_typeof(payload->'items') is distinct from 'array'
     or jsonb_array_length(payload->'items') not between 1 and 30 then
    return jsonb_build_object('ok', false, 'error', '購物車內容不正確');
  end if;

  -- 每筆數量須為 1–50(原:floor 後檢查範圍)
  select count(*) into v_n_valid
    from jsonb_array_elements(payload->'items') e
   where coalesce(e->>'qty', '') ~ '^[0-9]+(\.[0-9]+)?$'
     and floor((e->>'qty')::numeric) between 1 and 50;
  if v_n_valid <> jsonb_array_length(payload->'items') then
    return jsonb_build_object('ok', false, 'error', '商品數量不正確');
  end if;

  -- 以商品表重算;同一商品重複出現者合併為一列(原系統會變成兩列)
  select jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'price', p.price, 'qty', m.qty)),
         count(*), count(p.id), sum(p.price * m.qty)
    into v_lines, v_n_lines, v_n_found, v_sub
    from (select e->>'id' as id, sum(floor((e->>'qty')::numeric))::integer as qty
            from jsonb_array_elements(payload->'items') e
           group by 1) m
    left join public.products p on p.id = m.id and p.is_active;
  if v_n_found <> v_n_lines then
    return jsonb_build_object('ok', false, 'error', '部分商品已下架或不存在');
  end if;
  if exists (select 1 from jsonb_to_recordset(v_lines) as l(qty integer) where l.qty > 50) then
    return jsonb_build_object('ok', false, 'error', '商品數量不正確');
  end if;

  v_fee      := public.calc_fee(v_mode, v_sub);
  v_order_no := public.next_order_no();

  insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, customer_email,
                             store_id, ship_address, note, subtotal, fee, total)
  values (v_order_no, v_mode, v_name, v_phone, nullif(v_email, ''),
          v_store, v_addr, nullif(v_note, ''), v_sub, v_fee, v_sub + v_fee)
  returning id into v_id;

  insert into public.order_items (order_id, product_id, product_name, unit_price, quantity, line_total)
  select v_id, l.product_id, l.name, l.price, l.qty, l.price * l.qty
    from jsonb_to_recordset(v_lines) as l(product_id text, name text, price integer, qty integer);

  return jsonb_build_object('ok', true, 'order_no', v_order_no, 'total', v_sub + v_fee,
                            'eta', case when v_mode = 'ship' then '2–3 個工作天' else '約 15–20 分鐘' end);
end $$;

-- 顧客查單(取代 Apps Script track_):只憑訂單編號,只回品項/金額/狀態/時間,不含姓名、手機、地址。
create or replace function public.track_order(p_order_no text)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_no text := upper(btrim(coalesce(p_order_no, '')));
  o    public.orders%rowtype;
begin
  if v_no !~ '^JF[0-9]{6}-[0-9]{3,}$' then
    return jsonb_build_object('ok', false, 'error', '訂單編號格式不正確(例:JF251022-001)');
  end if;
  select * into o from public.orders where order_no = v_no;
  if not found then
    return jsonb_build_object('ok', false, 'error', '查無此訂單');
  end if;
  return jsonb_build_object(
    'ok', true, 'order_no', o.order_no, 'status', o.status, 'mode', o.fulfillment_type,
    'createdAt', o.created_at, 'updatedAt', o.updated_at,
    'subtotal', o.subtotal, 'fee', o.fee, 'total', o.total,
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'price', i.unit_price, 'qty', i.quantity)
                                        order by i.product_name)
                         from public.order_items i where i.order_id = o.id), '[]'::jsonb));
end $$;

-- 後台改狀態(取代 Apps Script admin_ 的 status):由 Edge Function 傳入已驗證的店員 user id。
-- 以 set_config('app.actor', …) 讓狀態紀錄觸發器知道是誰改的(service_role 沒有 auth.uid())。
create or replace function public.update_order_status(p_order_no text, p_status text, p_actor uuid)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_updated integer;
begin
  if p_actor is null or not public.is_staff(p_actor) then
    return jsonb_build_object('ok', false, 'error', '沒有權限', 'code', 'AUTH');
  end if;
  if p_status is null or p_status not in ('new','preparing','ready','delivering','done','cancelled') then
    return jsonb_build_object('ok', false, 'error', '狀態不正確');
  end if;
  perform set_config('app.actor', p_actor::text, true);   -- true = 僅在目前交易有效
  update public.orders set status = p_status where order_no = upper(btrim(coalesce(p_order_no, '')));
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    return jsonb_build_object('ok', false, 'error', '找不到訂單 ' || coalesce(p_order_no, ''));
  end if;
  return jsonb_build_object('ok', true, 'order_no', p_order_no, 'status', p_status);
end $$;

-- ============================================================================
-- 3. 觸發器:updated_at 與狀態紀錄
-- ============================================================================

create or replace function public.orders_before_update()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists orders_set_updated_at on public.orders;
create trigger orders_set_updated_at before update on public.orders
  for each row execute function public.orders_before_update();

-- 以 security definer 執行,讓 service_role 不需要 order_status_log 的寫入權限也能留下紀錄
create or replace function public.orders_log_status()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := nullif(current_setting('app.actor', true), '')::uuid;
begin
  if tg_op = 'INSERT' then
    insert into public.order_status_log (order_id, from_status, to_status, changed_by, changed_at)
    values (new.id, null, new.status, v_actor, new.created_at);
  elsif new.status is distinct from old.status then
    insert into public.order_status_log (order_id, from_status, to_status, changed_by)
    values (new.id, old.status, new.status, v_actor);
  end if;
  return null;
end $$;

drop trigger if exists orders_log_status_ins on public.orders;
create trigger orders_log_status_ins after insert on public.orders
  for each row execute function public.orders_log_status();

drop trigger if exists orders_log_status_upd on public.orders;
create trigger orders_log_status_upd after update of status on public.orders
  for each row execute function public.orders_log_status();

-- ============================================================================
-- 4. RLS 與權限
--    原則:訂單相關資料表啟用 RLS 且「不建立任何政策」→ anon / authenticated 一律看不到也寫不了;
--          後端使用 service_role(會繞過 RLS,但仍需要資料表權限,所以下面明確授權)。
--    Supabase 預設會把新資料表的權限自動授與 anon / authenticated / service_role,
--    因此必須先全部收回,再只授與需要的。
-- ============================================================================

alter table public.stores           enable row level security;
alter table public.products         enable row level security;
alter table public.orders           enable row level security;
alter table public.order_items      enable row level security;
alter table public.order_status_log enable row level security;
alter table public.order_counters   enable row level security;
alter table public.staff_members    enable row level security;

-- 先清空既有權限(只是權限,不影響資料)
revoke all on public.stores, public.products, public.orders, public.order_items,
              public.order_status_log, public.order_counters, public.staff_members
  from anon, authenticated, service_role;

-- 商品、門市:前端可用 anon key 直接讀「上架」資料;寫入只有後端(且不給 delete,下架請改 is_active)
grant select on public.stores, public.products to anon, authenticated;
grant select, insert, update on public.stores, public.products to service_role;

drop policy if exists stores_read_active   on public.stores;
drop policy if exists products_read_active on public.products;
create policy stores_read_active   on public.stores   for select to anon, authenticated using (is_active);
create policy products_read_active on public.products for select to anon, authenticated using (is_active);

-- 訂單相關:只有 service_role,且不給 delete / truncate
grant select, insert, update on public.orders         to service_role;
grant select, insert         on public.order_items    to service_role;
grant select                 on public.order_status_log to service_role;   -- 寫入由觸發器(security definer)負責
grant select, insert, update on public.order_counters to service_role;
grant select                 on public.staff_members  to service_role;    -- 店員名單由管理者在 Dashboard 維護

-- 函式:預設任何人可執行,先收回,只留給 service_role
revoke all on function public.calc_fee(text, integer)                  from public, anon, authenticated;
revoke all on function public.is_staff(uuid)                           from public, anon, authenticated;
revoke all on function public.next_order_no()                          from public, anon, authenticated;
revoke all on function public.create_order(jsonb)                      from public, anon, authenticated;
revoke all on function public.track_order(text)                        from public, anon, authenticated;
revoke all on function public.update_order_status(text, text, uuid)    from public, anon, authenticated;
revoke all on function public.orders_before_update()                   from public, anon, authenticated;
revoke all on function public.orders_log_status()                      from public, anon, authenticated;

grant execute on function public.calc_fee(text, integer)               to service_role;
grant execute on function public.is_staff(uuid)                        to service_role;
grant execute on function public.next_order_no()                       to service_role;
grant execute on function public.create_order(jsonb)                   to service_role;
grant execute on function public.track_order(text)                     to service_role;
grant execute on function public.update_order_status(text, text, uuid) to service_role;
-- 觸發器函式由資料庫在觸發時執行,不需要任何角色的 execute 權限。
