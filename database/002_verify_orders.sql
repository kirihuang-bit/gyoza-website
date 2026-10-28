-- ============================================================================
-- 002_verify_orders.sql — 建表後查核 + 使用虛構訂單的寫入/查詢測試
--
-- 執行方式:在 Supabase SQL Editor 以預設的 postgres 身分,先執行過 001_create_orders.sql,再整段執行本檔。
--
-- 保證不留資料:所有測試都在一個交易裡,最後一定以「刻意拋出錯誤」收尾,資料庫因此自動回滾,
--   (含虛構訂單、虛構商品/門市/店員、每日流水號計數器)全部不會保留。本檔不刪除任何既有資料。
--   ※ 所以執行結果會顯示一則「錯誤」,錯誤訊息的內容就是驗證報告。這是刻意設計。
--
-- 看報告:每行 [PASS] / [FAIL] / [SKIP];第一行為 VERIFY_OK 代表全部通過。
-- ============================================================================

begin;

-- 報告用的小工具(暫存函式,交易結束即消失)
create function pg_temp.chk(p_name text, p_ok boolean, p_detail text default '')
returns text language sql as $$
  select case when p_ok then '[PASS] ' else '[FAIL] ' end || p_name ||
         case when coalesce(p_detail, '') = '' then '' else ' — ' || p_detail end
$$;

do $verify$
declare
  v_lines   text[] := '{}';
  v_report  text;
  v_fail    integer;
  v_skip    integer;
  v_pass    integer;
  t         text;
  r         jsonb;
  r2        jsonb;
  v_ok      boolean;
  v_n       integer;
  v_n_before integer;
  v_staff   uuid := gen_random_uuid();
  v_staff_ready boolean := false;
  v_no1     text;
  v_no2     text;
  v_seq1    integer;
  v_seq2    integer;
  v_oid     uuid;
  v_created timestamptz;
  v_updated timestamptz;
begin
  ------------------------------------------------------------------------
  -- A. 結構檢查
  ------------------------------------------------------------------------
  foreach t in array array['stores','products','orders','order_items','order_status_log','order_counters','staff_members'] loop
    v_lines := v_lines || pg_temp.chk('資料表存在:' || t, to_regclass('public.' || t) is not null);
    v_lines := v_lines || pg_temp.chk('RLS 已啟用:' || t,
      coalesce((select relrowsecurity from pg_class where oid = to_regclass('public.' || t)), false));
  end loop;

  foreach t in array array['orders','order_items','order_status_log','order_counters','staff_members'] loop
    select count(*) into v_n from pg_policies where schemaname = 'public' and tablename = t;
    v_lines := v_lines || pg_temp.chk('訂單相關表沒有任何政策:' || t, v_n = 0, '政策數 = ' || v_n);
  end loop;

  select count(*) into v_n from pg_policies
   where schemaname = 'public' and tablename in ('stores','products') and cmd = 'SELECT';
  v_lines := v_lines || pg_temp.chk('stores / products 只有 SELECT 政策', v_n = 2
     and not exists (select 1 from pg_policies where schemaname = 'public'
                      and tablename in ('stores','products') and cmd <> 'SELECT'), '政策數 = ' || v_n);

  v_lines := v_lines || pg_temp.chk('orders.order_no 唯一',
    exists (select 1 from pg_constraint where conrelid = 'public.orders'::regclass and contype = 'u'));
  v_lines := v_lines || pg_temp.chk('orders 有 total = subtotal + fee 限制',
    exists (select 1 from pg_constraint where conname = 'orders_total_ok'));
  v_lines := v_lines || pg_temp.chk('orders 有宅配必填地址限制',
    exists (select 1 from pg_constraint where conname = 'orders_ship_addr'));
  v_lines := v_lines || pg_temp.chk('orders 有 updated_at 與狀態紀錄觸發器',
    (select count(*) from pg_trigger where tgrelid = 'public.orders'::regclass and not tgisinternal) = 3);

  ------------------------------------------------------------------------
  -- B. 權限檢查(anon / authenticated 不可碰訂單;service_role 只有需要的權限)
  ------------------------------------------------------------------------
  foreach t in array array['orders','order_items','order_status_log','order_counters','staff_members'] loop
    v_lines := v_lines || pg_temp.chk('anon 對 ' || t || ' 無任何權限',
      not (has_table_privilege('anon', 'public.' || t, 'SELECT') or has_table_privilege('anon', 'public.' || t, 'INSERT')
        or has_table_privilege('anon', 'public.' || t, 'UPDATE') or has_table_privilege('anon', 'public.' || t, 'DELETE')));
    v_lines := v_lines || pg_temp.chk('authenticated 對 ' || t || ' 無任何權限',
      not (has_table_privilege('authenticated', 'public.' || t, 'SELECT') or has_table_privilege('authenticated', 'public.' || t, 'INSERT')
        or has_table_privilege('authenticated', 'public.' || t, 'UPDATE') or has_table_privilege('authenticated', 'public.' || t, 'DELETE')));
  end loop;

  v_lines := v_lines || pg_temp.chk('service_role 可讀寫 orders',
    has_table_privilege('service_role', 'public.orders', 'SELECT') and has_table_privilege('service_role', 'public.orders', 'INSERT')
    and has_table_privilege('service_role', 'public.orders', 'UPDATE'));
  v_lines := v_lines || pg_temp.chk('service_role 不能刪除 / 清空 orders',
    not has_table_privilege('service_role', 'public.orders', 'DELETE') and not has_table_privilege('service_role', 'public.orders', 'TRUNCATE'));
  v_lines := v_lines || pg_temp.chk('anon 可讀 stores / products 但不可寫',
    has_table_privilege('anon', 'public.stores', 'SELECT') and has_table_privilege('anon', 'public.products', 'SELECT')
    and not has_table_privilege('anon', 'public.stores', 'INSERT') and not has_table_privilege('anon', 'public.products', 'UPDATE'));

  foreach t in array array['public.create_order(jsonb)','public.track_order(text)','public.update_order_status(text,text,uuid)','public.next_order_no()'] loop
    v_lines := v_lines || pg_temp.chk('函式只有 service_role 能執行:' || t,
      has_function_privilege('service_role', t, 'EXECUTE')
      and not has_function_privilege('anon', t, 'EXECUTE')
      and not has_function_privilege('authenticated', t, 'EXECUTE'));
  end loop;

  ------------------------------------------------------------------------
  -- C. 虛構資料(整個交易結束會回滾)
  ------------------------------------------------------------------------
  insert into public.stores (id, name, address) values ('zz_test_store', 'ZZ測試門市', '虛構地址 1 號');
  insert into public.products (id, name, price, category_key, category_label, is_active) values
    ('zz_test_p1',  'ZZ測試鍋貼', 100, 'signature', '招牌鍋貼', true),
    ('zz_test_p2',  'ZZ測試湯',    50, 'soup',      '湯品/飲料', true),
    ('zz_test_off', 'ZZ測試下架',  80, 'side',      '經典小菜', false);

  -- 虛構店員(需要 auth.users 一列;若此環境不允許則略過後台改狀態的測試)
  begin
    insert into auth.users (id, aud, role, email) values (v_staff, 'authenticated', 'authenticated', 'zz-test-staff@example.invalid');
    insert into public.staff_members (user_id, display_name) values (v_staff, 'ZZ測試店員');
    v_staff_ready := true;
  exception when others then
    v_lines := v_lines || '[SKIP] 建立虛構店員失敗,略過 update_order_status 測試 — ' || sqlerrm;
  end;

  -- 為了證明 anon 的 SELECT 政策只露出上架資料
  begin
    set local role anon;
    select count(*) into v_n from public.products where id like 'zz_test_%';
    reset role;
    v_lines := v_lines || pg_temp.chk('anon 只看得到上架商品(2 筆,下架的看不到)', v_n = 2, '看到 ' || v_n || ' 筆');
  exception when others then
    reset role;
    v_lines := v_lines || pg_temp.chk('anon 只看得到上架商品', false, sqlerrm);
  end;

  select count(*) into v_n_before from public.orders;

  ------------------------------------------------------------------------
  -- D. 以 service_role 身分(= Edge Function)呼叫:下單
  ------------------------------------------------------------------------
  set local role service_role;

  r := public.create_order(jsonb_build_object(
        'mode','dine','name','ZZ測試客','phone','0900000001','email','zz@example.invalid','store_id','zz_test_store',
        'note','少辣','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',2), jsonb_build_object('id','zz_test_p2','qty',1))));
  reset role;   -- 回到 postgres 記錄結果並讀取資料(注意:報告函式 chk 一律在 reset role 之後才呼叫)
  v_no1 := r->>'order_no';
  v_lines := v_lines || pg_temp.chk('下單成功:內用 100×2 + 50×1',
    (r->>'ok')::boolean and (r->>'total')::int = 275, 'total = ' || coalesce(r->>'total', 'null') || '(預期 250 + 服務費 25 = 275)');
  v_lines := v_lines || pg_temp.chk('訂單編號格式 JFyymmdd-nnn', v_no1 ~ '^JF[0-9]{6}-[0-9]{3,}$', coalesce(v_no1, 'null'));

  select id, created_at into v_oid, v_created from public.orders where order_no = v_no1;
  v_lines := v_lines || pg_temp.chk('主檔欄位:狀態 new、金額、門市',
    exists (select 1 from public.orders where id = v_oid and status = 'new' and subtotal = 250 and fee = 25 and total = 275
                                          and store_id = 'zz_test_store' and ship_address is null and customer_email = 'zz@example.invalid'));
  v_lines := v_lines || pg_temp.chk('明細 2 列且為品名/單價快照',
    (select count(*) from public.order_items where order_id = v_oid) = 2
    and exists (select 1 from public.order_items where order_id = v_oid and product_id = 'zz_test_p1' and product_name = 'ZZ測試鍋貼' and unit_price = 100 and quantity = 2 and line_total = 200));
  v_lines := v_lines || pg_temp.chk('明細小計加總 = 訂單小計',
    (select sum(line_total) from public.order_items where order_id = v_oid) = (select subtotal from public.orders where id = v_oid));
  v_lines := v_lines || pg_temp.chk('狀態紀錄 1 筆(null → new)',
    (select count(*) from public.order_status_log where order_id = v_oid and from_status is null and to_status = 'new') = 1);

  -- 第二張單:同商品重複出現應合併;外帶無費用;流水號 +1
  set local role service_role;
  r2 := public.create_order(jsonb_build_object(
        'mode','take','name','ZZ測試客二','phone','0900000002','store_id','zz_test_store',
        'items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1), jsonb_build_object('id','zz_test_p1','qty',2))));
  v_no2 := r2->>'order_no';
  reset role;
  v_lines := v_lines || pg_temp.chk('重複商品合併為 1 列、數量 3;外帶無費用',
    (r2->>'ok')::boolean and (r2->>'total')::int = 300
    and (select count(*) from public.order_items i join public.orders o on o.id = i.order_id where o.order_no = v_no2) = 1
    and (select quantity from public.order_items i join public.orders o on o.id = i.order_id where o.order_no = v_no2) = 3);
  v_seq1 := split_part(v_no1, '-', 2)::int;
  v_seq2 := split_part(v_no2, '-', 2)::int;
  v_lines := v_lines || pg_temp.chk('流水號遞增', v_seq2 = v_seq1 + 1, v_no1 || ' → ' || v_no2);

  -- 運費規則
  set local role service_role;
  r := public.create_order(jsonb_build_object('mode','ship','name','ZZ宅配','phone','0900000003','address','虛構路 1 號',
        'items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1))));
  r2 := public.create_order(jsonb_build_object('mode','ship','name','ZZ宅配','phone','0900000003','address','虛構路 1 號',
        'items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',10))));
  reset role;
  v_lines := v_lines || pg_temp.chk('宅配未滿 1000 運費 150', (r->>'ok')::boolean and (r->>'total')::int = 250, 'total = ' || coalesce(r->>'total', 'null'));
  v_lines := v_lines || pg_temp.chk('宅配滿 1000 免運',      (r2->>'ok')::boolean and (r2->>'total')::int = 1000, 'total = ' || coalesce(r2->>'total', 'null'));
  v_lines := v_lines || pg_temp.chk('宅配訂單不存門市、存地址',
    exists (select 1 from public.orders where order_no = r->>'order_no' and store_id is null and ship_address = '虛構路 1 號'));

  ------------------------------------------------------------------------
  -- E. 應被拒絕的下單(每一項都必須 ok = false 且不寫入任何訂單)
  ------------------------------------------------------------------------
  set local role service_role;
  declare
    v_cases jsonb := jsonb_build_object(
      '手機格式錯誤', jsonb_build_object('mode','take','name','X','phone','123','store_id','zz_test_store','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1))),
      '姓名空白',     jsonb_build_object('mode','take','name',' ','phone','0900000009','store_id','zz_test_store','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1))),
      'Email 格式錯誤', jsonb_build_object('mode','take','name','X','phone','0900000009','email','abc','store_id','zz_test_store','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1))),
      '取餐方式不存在', jsonb_build_object('mode','fly','name','X','phone','0900000009','store_id','zz_test_store','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1))),
      '宅配沒有地址', jsonb_build_object('mode','ship','name','X','phone','0900000009','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1))),
      '內用沒有選門市', jsonb_build_object('mode','dine','name','X','phone','0900000009','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1))),
      '門市不存在',   jsonb_build_object('mode','dine','name','X','phone','0900000009','store_id','nope','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1))),
      '商品已下架',   jsonb_build_object('mode','take','name','X','phone','0900000009','store_id','zz_test_store','items', jsonb_build_array(jsonb_build_object('id','zz_test_off','qty',1))),
      '商品不存在',   jsonb_build_object('mode','take','name','X','phone','0900000009','store_id','zz_test_store','items', jsonb_build_array(jsonb_build_object('id','nope','qty',1))),
      '數量為 0',     jsonb_build_object('mode','take','name','X','phone','0900000009','store_id','zz_test_store','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',0))),
      '數量超過 50',  jsonb_build_object('mode','take','name','X','phone','0900000009','store_id','zz_test_store','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',51))),
      '合併後數量超過 50', jsonb_build_object('mode','take','name','X','phone','0900000009','store_id','zz_test_store','items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',30), jsonb_build_object('id','zz_test_p1','qty',30))),
      '購物車是空的', jsonb_build_object('mode','take','name','X','phone','0900000009','store_id','zz_test_store','items', jsonb_build_array()),
      '缺少 items',   jsonb_build_object('mode','take','name','X','phone','0900000009','store_id','zz_test_store'));
    k text;
    v_before integer;
    v_res jsonb := '{}';
  begin
    reset role;
    select count(*) into v_before from public.orders;
    set local role service_role;
    for k in select jsonb_object_keys(v_cases) loop
      v_res := v_res || jsonb_build_object(k, public.create_order(v_cases->k));
    end loop;
    reset role;
    for k in select jsonb_object_keys(v_res) loop
      v_lines := v_lines || pg_temp.chk('拒絕:' || k, (v_res->k->>'ok')::boolean is false, coalesce(v_res->k->>'error', '(沒有拒絕!)'));
    end loop;
    select count(*) into v_n from public.orders;
    v_lines := v_lines || pg_temp.chk('被拒絕的下單沒有寫入任何訂單', v_n = v_before, '前 ' || v_before || ' / 後 ' || v_n);
  end;

  -- honeypot:假裝成功但不寫入
  select count(*) into v_n_before from public.orders;
  set local role service_role;
  r := public.create_order(jsonb_build_object('hp','bot','mode','take','name','X','phone','0900000009','store_id','zz_test_store',
        'items', jsonb_build_array(jsonb_build_object('id','zz_test_p1','qty',1))));
  reset role;
  select count(*) into v_n from public.orders;
  v_lines := v_lines || pg_temp.chk('honeypot:回傳成功但不寫入', (r->>'ok')::boolean and r->>'order_no' = 'JF-IGNORED' and v_n = v_n_before);

  ------------------------------------------------------------------------
  -- F. 顧客查單
  ------------------------------------------------------------------------
  set local role service_role;
  r  := public.track_order(lower(v_no1));   -- 小寫也應可查
  r2 := jsonb_build_object('bad', public.track_order('abc'), 'none', public.track_order('JF000101-001'));
  reset role;
  v_lines := v_lines || pg_temp.chk('查單成功:狀態 new、2 個品項、金額',
    (r->>'ok')::boolean and r->>'status' = 'new' and jsonb_array_length(r->'items') = 2 and (r->>'total')::int = 275);
  v_lines := v_lines || pg_temp.chk('查單結果不含個資(姓名、手機、Email、地址、備註)',
    r::text not like '%ZZ測試客%' and r::text not like '%0900000001%' and r::text not like '%zz@example%' and r::text not like '%少辣%');
  v_lines := v_lines || pg_temp.chk('查單:格式錯誤被拒', (r2->'bad'->>'ok')::boolean is false);
  v_lines := v_lines || pg_temp.chk('查單:查無此單', (r2->'none'->>'ok')::boolean is false and r2->'none'->>'error' = '查無此訂單');

  ------------------------------------------------------------------------
  -- G. 後台改狀態(需要虛構店員)
  ------------------------------------------------------------------------
  if v_staff_ready then
    -- now() 在同一個交易內不變:暫停 updated_at 觸發器,把 updated_at 調到一小時前,才能看出之後有被更新
    alter table public.orders disable trigger orders_set_updated_at;
    update public.orders set updated_at = now() - interval '1 hour' where id = v_oid;
    alter table public.orders enable trigger orders_set_updated_at;
    select updated_at into v_created from public.orders where id = v_oid;   -- 這裡借用 v_created 存「更新前」的 updated_at
    set local role service_role;
    r := public.update_order_status(v_no1, 'preparing', v_staff);
    reset role;
    select updated_at into v_updated from public.orders where id = v_oid;
    v_lines := v_lines || pg_temp.chk('店員改狀態成功',   (r->>'ok')::boolean and (select status from public.orders where id = v_oid) = 'preparing');
    v_lines := v_lines || pg_temp.chk('updated_at 被更新', v_updated > v_created, '更新前 ' || v_created || ' / 更新後 ' || v_updated);
    v_lines := v_lines || pg_temp.chk('狀態紀錄新增 new → preparing 並記錄店員',
      exists (select 1 from public.order_status_log where order_id = v_oid and from_status = 'new' and to_status = 'preparing' and changed_by = v_staff));
    v_lines := v_lines || pg_temp.chk('狀態紀錄共 2 筆', (select count(*) from public.order_status_log where order_id = v_oid) = 2);

    set local role service_role;
    r2 := jsonb_build_object(
      'bogus',  public.update_order_status(v_no1, 'bogus', v_staff),
      'nonstaff', public.update_order_status(v_no1, 'ready', gen_random_uuid()),
      'missing', public.update_order_status('JF000101-001', 'ready', v_staff));
    reset role;
    v_lines := v_lines || pg_temp.chk('拒絕不存在的狀態', (r2->'bogus'->>'ok')::boolean is false, coalesce(r2->'bogus'->>'error', ''));
    v_lines := v_lines || pg_temp.chk('拒絕非店員操作', (r2->'nonstaff'->>'ok')::boolean is false and r2->'nonstaff'->>'code' = 'AUTH');
    v_lines := v_lines || pg_temp.chk('找不到訂單時回報錯誤', (r2->'missing'->>'ok')::boolean is false);
    v_lines := v_lines || pg_temp.chk('被拒絕的狀態更新沒有改變資料', (select status from public.orders where id = v_oid) = 'preparing');
  end if;

  ------------------------------------------------------------------------
  -- H. 反向測試:anon / authenticated 不能碰訂單,也不能呼叫 RPC
  ------------------------------------------------------------------------
  foreach t in array array['anon','authenticated'] loop
    begin
      execute format('set local role %I', t);
      perform 1 from public.orders limit 1;
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能讀取 orders', false, '竟然讀得到');
    exception when insufficient_privilege then
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能讀取 orders', true, 'permission denied');
    end;

    begin
      execute format('set local role %I', t);
      insert into public.orders (order_no, fulfillment_type, customer_name, customer_phone, subtotal, total)
        values ('JF000101-999', 'take', 'ZZ', '0900000000', 1, 1);
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能寫入 orders', false, '竟然寫得進去');
    exception when insufficient_privilege then
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能寫入 orders', true, 'permission denied');
    end;

    begin
      execute format('set local role %I', t);
      perform 1 from public.order_items limit 1;
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能讀取 order_items', false, '竟然讀得到');
    exception when insufficient_privilege then
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能讀取 order_items', true, 'permission denied');
    end;

    begin
      execute format('set local role %I', t);
      perform public.create_order('{}'::jsonb);
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能呼叫 create_order', false, '竟然可以呼叫');
    exception when insufficient_privilege then
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能呼叫 create_order', true, 'permission denied');
    end;

    begin
      execute format('set local role %I', t);
      perform public.track_order('JF000101-001');
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能直接呼叫 track_order(須經 Edge Function)', false, '竟然可以呼叫');
    exception when insufficient_privilege then
      reset role;
      v_lines := v_lines || pg_temp.chk(t || ' 不能直接呼叫 track_order(須經 Edge Function)', true, 'permission denied');
    end;
  end loop;

  ------------------------------------------------------------------------
  -- I. 彙整報告,並以拋出錯誤的方式強制整個交易回滾
  ------------------------------------------------------------------------
  select count(*) filter (where l like '[FAIL]%'), count(*) filter (where l like '[SKIP]%'), count(*) filter (where l like '[PASS]%')
    into v_fail, v_skip, v_pass
    from unnest(v_lines) l;

  v_report := case when v_fail = 0 then 'VERIFY_OK' else 'VERIFY_FAILED' end
    || E' — 通過 ' || v_pass || ' / 失敗 ' || v_fail || ' / 略過 ' || v_skip
    || E'(此「錯誤」是刻意的:用來強制回滾,所有虛構資料不會保留)\n'
    || array_to_string(v_lines, E'\n');
  raise exception E'%', v_report;
end
$verify$;

-- 若你的工具在上面的錯誤後仍繼續執行,以下確保交易結束(此時資料庫已回滾)
rollback;

-- ============================================================================
-- 回滾後的確認(選用,另外執行):以下三個查詢的結果都應該是 0。
--   select count(*) from public.orders   where customer_name like 'ZZ%';
--   select count(*) from public.products where id like 'zz_test_%';
--   select count(*) from public.stores   where id like 'zz_test_%';
-- ============================================================================
