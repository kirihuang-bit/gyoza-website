// create-order — 接收網站送出的訂單,呼叫資料庫函式 public.create_order(payload jsonb)。
//
// 依據:database/001_create_orders.sql
//   - create_order 只授權給 service_role,所以本函式用 SUPABASE_SERVICE_ROLE_KEY 呼叫。
//   - 金額、訂單編號、商品與門市是否有效、手機/Email 格式、數量範圍,全都由資料庫函式驗證與計算;
//     這裡只做「進資料庫之前」的輸入檢查(型別、長度、大小),不重複實作業務規則。
//
// 環境變數(皆由 Supabase 平台或你在 Dashboard 設定,不寫在程式裡):
//   SUPABASE_URL                 平台自動提供
//   SUPABASE_SERVICE_ROLE_KEY    平台自動提供(只存在於後端,絕不可出現在前端)
//   ALLOWED_ORIGINS              選填。允許呼叫的網站來源,逗號分隔,例如 https://your-name.github.io
//                                未設定時允許任何來源(*)。

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const MAX_BODY_BYTES = 32 * 1024;
const MAX_STRING_LENGTH = 1000;
const MAX_ITEMS = 30; // 與資料庫函式的上限一致
const MAX_ID_LENGTH = 100;

// 前端傳來、允許轉交給資料庫的文字欄位(其餘欄位一律丟棄)
const STRING_FIELDS = ["mode", "name", "phone", "email", "store_id", "store", "address", "note", "hp"] as const;

/* ---------- CORS / 回應 ---------- */

function corsHeaders(req: Request): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
  };
  const allowed = (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (allowed.length === 0) {
    headers["Access-Control-Allow-Origin"] = "*";
    return headers;
  }
  headers["Vary"] = "Origin";
  const origin = req.headers.get("origin") ?? "";
  if (allowed.includes(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

function respond(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), "Content-Type": "application/json; charset=utf-8" },
  });
}

const fail = (req: Request, status: number, error: string) => respond(req, status, { ok: false, error });

/* ---------- 輸入檢查 ---------- */

type Json = Record<string, unknown>;
const isObject = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);

/** 回傳整理後的 payload,或錯誤訊息。 */
function sanitize(body: unknown): { payload: Json } | { error: string } {
  if (!isObject(body)) return { error: "請求內容格式不正確" };

  const payload: Json = {};
  for (const key of STRING_FIELDS) {
    const value = body[key];
    if (value === undefined || value === null) continue;
    if (typeof value !== "string") return { error: `欄位 ${key} 格式不正確` };
    if (value.length > MAX_STRING_LENGTH) return { error: `欄位 ${key} 內容過長` };
    payload[key] = value;
  }

  const items = body.items;
  if (!Array.isArray(items) || items.length > MAX_ITEMS) return { error: "購物車內容不正確" };
  const cleanItems: { id: string; qty: number }[] = [];
  for (const item of items) {
    if (!isObject(item) || typeof item.id !== "string" || item.id.length === 0 || item.id.length > MAX_ID_LENGTH ||
        typeof item.qty !== "number" || !Number.isFinite(item.qty)) {
      return { error: "購物車內容不正確" };
    }
    cleanItems.push({ id: item.id, qty: item.qty });
  }
  payload.items = cleanItems;
  return { payload };
}

/* ---------- 主程式 ---------- */

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req) });
  if (req.method !== "POST") return fail(req, 405, "只接受 POST");

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) {
      console.error("missing env:", [!url && "SUPABASE_URL", !serviceKey && "SUPABASE_SERVICE_ROLE_KEY"].filter(Boolean).join(","));
      return fail(req, 500, "系統設定錯誤");
    }

    // 讀取 body。接受 application/json 與 text/plain(現有前端用 text/plain 以避免 CORS 預檢)。
    const declared = Number(req.headers.get("content-length") ?? "0");
    if (declared > MAX_BODY_BYTES) return fail(req, 413, "請求內容過大");
    const raw = await req.text();
    if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) return fail(req, 413, "請求內容過大");

    let body: unknown;
    try {
      body = JSON.parse(raw);
    } catch {
      return fail(req, 400, "請求內容不是有效的 JSON");
    }

    const checked = sanitize(body);
    if ("error" in checked) return fail(req, 400, checked.error);
    const payload = checked.payload;

    const supabase = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });

    // 相容現有前端:前端送的是 store(下拉文字「旗艦店 — 地址」),資料庫要的是 store_id。
    // 有 store_id 就直接用;否則取「 — 」前的門市名稱,到 stores 表(僅上架)查出 id。查不到或不唯一就拒絕,不猜測。
    const legacyStore = typeof payload.store === "string" ? payload.store.trim() : "";
    if (payload.mode === "ship") {
      delete payload.store_id;
    } else if (!payload.store_id && legacyStore !== "") {
      const storeName = legacyStore.split(/\s*[—–]\s*/)[0].trim();
      const { data: stores, error: storeError } = await supabase
        .from("stores").select("id").eq("name", storeName).eq("is_active", true).limit(2);
      if (storeError) {
        console.error("stores lookup failed:", storeError.code);
        return fail(req, 500, "系統忙碌中,請稍後再試");
      }
      if (!stores || stores.length !== 1) return fail(req, 400, "請選擇取餐門市");
      payload.store_id = stores[0].id;
    }
    delete payload.store;

    const { data, error } = await supabase.rpc("create_order", { payload });
    if (error) {
      // 只記錄錯誤代碼:錯誤訊息可能夾帶訂單內容(姓名、手機等個資)
      console.error("create_order rpc failed:", error.code);
      return fail(req, 500, "系統忙碌中,請稍後再試");
    }
    if (!isObject(data)) {
      console.error("create_order returned unexpected shape");
      return fail(req, 500, "系統忙碌中,請稍後再試");
    }

    if (data.ok !== true) {
      // 資料庫函式的驗證失敗(手機格式、商品下架、數量不正確…),訊息原樣回傳
      return fail(req, 400, typeof data.error === "string" ? data.error : "訂單送出失敗");
    }

    // 原樣回傳資料庫欄位(order_no、total、eta),另加現有前端使用的別名 orderNo
    return respond(req, 200, { ...data, orderNo: data.order_no });
  } catch (err) {
    console.error("create-order unexpected error:", err instanceof Error ? err.name : "unknown");
    return fail(req, 500, "系統忙碌中,請稍後再試");
  }
});
