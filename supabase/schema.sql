-- 煎福鍋貼 · Supabase 資料表草稿(僅供審閱,尚未在任何資料庫執行)
-- 對應來源:gas/Code.gs 的「訂單」「訂單明細」「商品」工作表與 doPost / track_ / admin_
-- 已確認決定:英文狀態碼 + 狀態紀錄表、取餐方式代碼、stores 表、uuid 主鍵 + 唯一 order_no、
--           商品完整入庫、Postgres RPC 下單、查單只憑編號、後台 Supabase Auth

create extension if not exists pgcrypto;

/* ========== 門市 ========== */
create table public.stores (
  id          text primary key,                 -- flag / xinyi / taichung(與前端 STORES.id 一致)
  name        text not null,
  address     text not null,
  phone       text,
  sort_order  integer not null default 0,
  is_active   boolean not null default true
);

/* ========== 商品(取代「商品」工作表 + 前端寫死的 MENU / GIFTS) ========== */
create table public.products (
  id              text primary key,             -- s1, d1, p1, k1, g1 ...
  name            text not null,
  price           integer not null check (price >= 0),   -- 整數新台幣
  category_key    text not null,                -- signature / dumpling / soup / side / gift
  category_label  text not null,                -- 招牌鍋貼 等(原「商品」工作表 D 欄)
  description     text,
  image_url       text,
  tags            text[] not null default '{}',
  sub_label       text,                         -- 禮盒副標(GIFTS.sub)
  badge           text,                         -- 禮盒徽章(GIFTS.badge)
  sort_order      integer not null default 0,
  is_active       boolean not null default true -- 原「上架(TRUE/FALSE)」
);

/* ========== 訂單 ========== */
create table public.orders (
  id              uuid primary key default gen_random_uuid(),
  order_no        text not null unique,                      -- JF251022-001
  status          text not null default 'new'
                    check (status in ('new','preparing','ready','delivering','done','cancelled')),
  fulfillment_type text not null check (fulfillment_type in ('dine','take','ship')),
  customer_name   text not null check (length(btrim(customer_name)) > 0),
  customer_phone  text not null check (customer_phone ~ '^09[0-9]{8}$'),
  customer_email  text check (customer_email is null or customer_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  store_id        text references public.stores(id),
  ship_address    text,
  note            text,
  subtotal        integer not null check (subtotal >= 0),
  fee             integer not null default 0 check (fee >= 0),
  total           integer not null check (total >= 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint orders_total_ok  check (total = subtotal + fee),
  constraint orders_ship_addr check (fulfillment_type <> 'ship' or length(btrim(coalesce(ship_address,''))) > 0)
  -- 備註:舊系統「內用/外帶」未強制選門市,為相容舊資料遷移,這裡不對 store_id 加 not null;
  --       新單由 create_order() 要求必填。
);
create index orders_created_at_idx on public.orders (created_at desc);
create index orders_status_idx     on public.orders (status);

/* ========== 訂單明細(一個品項一列;品名/單價為下單當下快照) ========== */
create table public.order_items (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.orders(id) on delete cascade,
  product_id    text references public.products(id) on delete set null,
  product_name  text not null,
  unit_price    integer not null check (unit_price >= 0),
  quantity      integer not null check (quantity between 1 and 50),
  line_total    integer not null check (line_total = unit_price * quantity)
);
create index order_items_order_idx on public.order_items (order_id);

/* ========== 狀態變更紀錄 ========== */
create table public.order_status_log (
  id           bigint generated always as identity primary key,
  order_id     uuid not null references public.orders(id) on delete cascade,
  from_status  text,
  to_status    text not null,
  changed_by   uuid,                                  -- auth.uid();匿名下單為 null
  changed_at   timestamptz not null default now()
);
create index order_status_log_order_idx on public.order_status_log (order_id, changed_at);

/* ========== 每日訂單流水號 ========== */
create table public.order_counters (
  day       date primary key,                         -- 台北時間的日期
  last_seq  integer not null
);

/* ========== 店員 ========== */
create table public.staff_members (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  display_name  text
);

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.staff_members where user_id = auth.uid()) $$;

/* ========== 費用規則(與 Code.gs FEES 相同;日後只需改這一處) ========== */
create or replace function public.calc_fee(p_mode text, p_subtotal integer) returns integer
language sql immutable as $$
  select case p_mode
    when 'dine' then round(p_subtotal * 0.1)::integer
    when 'take' then 0
    when 'ship' then case when p_subtotal >= 1000 then 0 else 150 end
  end
$$;

/* ========== 訂單編號:JF + yyMMdd(台北時間)+ 流水號(不足 3 位補 0,超過 999 不截斷) ========== */
create or replace function public.next_order_no() returns text
language plpgsql security definer set search_path = public as $$
declare
  v_day date := (now() at time zone 'Asia/Taipei')::date;
  v_seq integer;
begin
  insert into order_counters (day, last_seq) values (v_day, 1)
  on conflict (day) do update set last_seq = order_counters.last_seq + 1
  returning last_seq into v_seq;
  return 'JF' || to_char(v_day, 'YYMMDD') || '-' ||
         case when v_seq < 1000 then lpad(v_seq::text, 3, '0') else v_seq::text end;
end $$;

/* ========== triggers:updated_at、狀態紀錄 ========== */
create or replace function public.orders_before_update() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
create trigger orders_set_updated_at before update on public.orders
  for each row execute function public.orders_before_update();

create or replace function public.orders_log_status() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into order_status_log (order_id, from_status, to_status, changed_by, changed_at)
    values (new.id, null, new.status, auth.uid(), new.created_at);
  elsif new.status is distinct from old.status then
    insert into order_status_log (order_id, from_status, to_status, changed_by)
    values (new.id, old.status, new.status, auth.uid());
  end if;
  return null;
end $$;
create trigger orders_log_status_ins after insert on public.orders
  for each row execute function public.orders_log_status();
create trigger orders_log_status_upd after update of status on public.orders
  for each row execute function public.orders_log_status();

/* ========== RPC:下單(取代 doPost;金額一律在資料庫重算,不信任前端) ========== */
create or replace function public.create_order(payload jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_mode   text := payload->>'mode';
  v_name   text := left(btrim(regexp_replace(coalesce(payload->>'name',  ''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_phone  text := left(btrim(regexp_replace(coalesce(payload->>'phone', ''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_email  text := left(btrim(regexp_replace(coalesce(payload->>'email', ''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_addr   text := left(btrim(regexp_replace(coalesce(payload->>'address',''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_note   text := left(btrim(regexp_replace(coalesce(payload->>'note',  ''), '[\x01-\x1f]', ' ', 'g')), 200);
  v_store  text := nullif(btrim(coalesce(payload->>'store_id', '')), '');
  v_lines  jsonb;
  v_n_in   integer;
  v_n_ok   integer;
  v_sub    integer;
  v_fee    integer;
  v_order_no text;
  v_id     uuid;
begin
  -- honeypot:機器人靜默略過(與原本行為一致)
  if coalesce(payload->>'hp', '') <> '' then
    return jsonb_build_object('ok', true, 'order_no', 'JF-IGNORED');
  end if;

  if v_mode is null or v_mode not in ('dine','take','ship') then
    return jsonb_build_object('ok', false, 'error', '取餐方式不正確');
  end if;
  if v_name = ''                      then return jsonb_build_object('ok', false, 'error', '請填寫姓名'); end if;
  if v_phone !~ '^09[0-9]{8}$'        then return jsonb_build_object('ok', false, 'error', '手機號碼格式不正確'); end if;
  if v_email <> '' and v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    return jsonb_build_object('ok', false, 'error', 'Email 格式不正確');
  end if;
  if v_mode = 'ship' then
    if v_addr = '' then return jsonb_build_object('ok', false, 'error', '宅配需填寫地址'); end if;
    v_store := null;
  else
    v_addr := null;
    if v_store is null or not exists (select 1 from stores where id = v_store and is_active) then
      return jsonb_build_object('ok', false, 'error', '請選擇取餐門市');
    end if;
  end if;

  if jsonb_typeof(payload->'items') is distinct from 'array'
     or jsonb_array_length(payload->'items') not between 1 and 30 then
    return jsonb_build_object('ok', false, 'error', '購物車內容不正確');
  end if;

  -- 每筆數量須為 1–50 的整數(原 floor + 範圍檢查);同商品重複者合併為一列
  select count(*) into v_n_in from jsonb_array_elements(payload->'items') e
   where coalesce(e->>'qty', '') ~ '^[0-9]+(\.[0-9]+)?$' and floor((e->>'qty')::numeric) between 1 and 50;
  if v_n_in <> jsonb_array_length(payload->'items') then
    return jsonb_build_object('ok', false, 'error', '商品數量不正確');
  end if;

  select jsonb_agg(jsonb_build_object('product_id', p.id, 'name', p.name, 'price', p.price, 'qty', m.qty)),
         count(*), count(p.id), sum(p.price * m.qty)
    into v_lines, v_n_in, v_n_ok, v_sub
    from (select e->>'id' as id, sum(floor((e->>'qty')::numeric))::integer as qty
            from jsonb_array_elements(payload->'items') e group by 1) m
    left join products p on p.id = m.id and p.is_active;
  if v_n_ok <> v_n_in then
    return jsonb_build_object('ok', false, 'error', '部分商品已下架或不存在');
  end if;
  if exists (select 1 from jsonb_to_recordset(v_lines) as l(qty integer) where l.qty > 50) then
    return jsonb_build_object('ok', false, 'error', '商品數量不正確');
  end if;

  v_fee      := calc_fee(v_mode, v_sub);
  v_order_no := next_order_no();

  insert into orders (order_no, fulfillment_type, customer_name, customer_phone, customer_email,
                      store_id, ship_address, note, subtotal, fee, total)
  values (v_order_no, v_mode, v_name, v_phone, nullif(v_email, ''),
          v_store, v_addr, nullif(v_note, ''), v_sub, v_fee, v_sub + v_fee)
  returning id into v_id;

  insert into order_items (order_id, product_id, product_name, unit_price, quantity, line_total)
  select v_id, l.product_id, l.name, l.price, l.qty, l.price * l.qty
    from jsonb_to_recordset(v_lines) as l(product_id text, name text, price integer, qty integer);

  return jsonb_build_object('ok', true, 'order_no', v_order_no, 'total', v_sub + v_fee,
                            'eta', case when v_mode = 'ship' then '2–3 個工作天' else '約 15–20 分鐘' end);
end $$;

/* ========== RPC:顧客查單(取代 track_;只憑訂單編號,不回傳任何個資) ========== */
create or replace function public.track_order(p_order_no text) returns jsonb
language plpgsql security definer stable set search_path = public as $$
declare
  v_no text := upper(btrim(coalesce(p_order_no, '')));
  o orders%rowtype;
begin
  if v_no !~ '^JF[0-9]{6}-[0-9]{3,}$' then
    return jsonb_build_object('ok', false, 'error', '訂單編號格式不正確(例:JF251022-001)');
  end if;
  select * into o from orders where order_no = v_no;
  if not found then
    return jsonb_build_object('ok', false, 'error', '查無此訂單');
  end if;
  return jsonb_build_object(
    'ok', true, 'order_no', o.order_no, 'status', o.status, 'mode', o.fulfillment_type,
    'createdAt', o.created_at, 'updatedAt', o.updated_at,
    'subtotal', o.subtotal, 'fee', o.fee, 'total', o.total,
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', i.product_name, 'price', i.unit_price, 'qty', i.quantity)
                                         order by i.product_name)
                         from order_items i where i.order_id = o.id), '[]'::jsonb));
end $$;

/* ========== RLS 與權限 ========== */
alter table public.stores            enable row level security;
alter table public.products          enable row level security;
alter table public.orders            enable row level security;
alter table public.order_items       enable row level security;
alter table public.order_status_log  enable row level security;
alter table public.order_counters    enable row level security;
alter table public.staff_members     enable row level security;

-- 匿名/顧客:只能讀上架的門市與商品;訂單相關資料表完全不可直接讀寫(只能透過 RPC)
create policy stores_read   on public.stores   for select to anon, authenticated using (is_active or public.is_staff());
create policy products_read on public.products for select to anon, authenticated using (is_active or public.is_staff());
create policy stores_staff_write   on public.stores   for all to authenticated using (public.is_staff()) with check (public.is_staff());
create policy products_staff_write on public.products for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- 店員:可讀所有訂單相關資料,且只能改訂單的「狀態」欄位
create policy orders_staff_read  on public.orders           for select to authenticated using (public.is_staff());
create policy orders_staff_upd   on public.orders           for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy items_staff_read   on public.order_items      for select to authenticated using (public.is_staff());
create policy log_staff_read     on public.order_status_log for select to authenticated using (public.is_staff());
create policy staff_self_read    on public.staff_members    for select to authenticated using (user_id = auth.uid());

revoke update on public.orders from anon, authenticated;
grant  update (status) on public.orders to authenticated;

-- RPC:預設公開執行權限收回,只開放必要者
revoke execute on function public.create_order(jsonb)  from public;
revoke execute on function public.track_order(text)    from public;
revoke execute on function public.next_order_no()      from public;
grant  execute on function public.create_order(jsonb)  to anon, authenticated;
grant  execute on function public.track_order(text)    to anon, authenticated;
