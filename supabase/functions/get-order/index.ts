// get-order — 顧客查詢訂單,呼叫資料庫函式 public.track_order(p_order_no text)。
//
// 依據:database/001_create_orders.sql
//   - track_order 只授權給 service_role,所以本函式用 SUPABASE_SERVICE_ROLE_KEY 呼叫。
//   - 回傳內容以 track_order 允許的為限:訂單編號、狀態、取餐方式、建立/更新時間、小計、費用、總額、品項。
//     不含姓名、手機、Email、地址、備註。
//
// ⚠️ 重要限制:本查詢「只憑訂單編號」。
//   - 沒有驗證查詢者的身分,也沒有驗證訂單所有權;任何知道(或猜到)訂單編號的人,都能看到該訂單的品項、金額、狀態與時間。
//   - 編號格式有規律(JF + 日期 + 當日流水號),可被推測;目前也沒有流量限制。
//   - 若要加強,需要同時修改資料庫函式(例如要求「訂單編號 + 手機後三碼」)並加上流量限制;本函式不宣稱已做到這些。
//
// 環境變數:
//   SUPABASE_URL                 平台自動提供
//   SUPABASE_SERVICE_ROLE_KEY    平台自動提供(只存在於後端,絕不可出現在前端)
//   ALLOWED_ORIGINS              選填。允許呼叫的網站來源,逗號分隔;未設定時允許任何來源(*)。

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const MAX_BODY_BYTES = 4 * 1024;
const MAX_ORDER_NO_LENGTH = 40;

// 資料庫存英文狀態碼;這是顯示用的中文別名(與現有前端、後台的六種狀態一致)
const STATUS_LABEL: Record<string, string> = {
  new: "新訂單",
  preparing: "製作中",
  ready: "待取餐",
  delivering: "配送中",
  done: "已完成",
  cancelled: "已取消",
};

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

type Json = Record<string, unknown>;
const isObject = (v: unknown): v is Json => typeof v === "object" && v !== null && !Array.isArray(v);

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
    if (!isObject(body)) return fail(req, 400, "請求內容格式不正確");

    // 接受 order_no,也接受現有前端使用的 orderNo
    const orderNo = body.order_no ?? body.orderNo;
    if (typeof orderNo !== "string" || orderNo.trim() === "") return fail(req, 400, "請輸入訂單編號");
    if (orderNo.length > MAX_ORDER_NO_LENGTH) return fail(req, 400, "訂單編號格式不正確");

    const supabase = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data, error } = await supabase.rpc("track_order", { p_order_no: orderNo });
    if (error) {
      console.error("track_order rpc failed:", error.code);
      return fail(req, 500, "系統忙碌中,請稍後再試");
    }
    if (!isObject(data)) {
      console.error("track_order returned unexpected shape");
      return fail(req, 500, "系統忙碌中,請稍後再試");
    }

    if (data.ok !== true) {
      const message = typeof data.error === "string" ? data.error : "查詢失敗";
      // 資料庫函式以此訊息表示找不到;其餘(格式錯誤)為 400
      return fail(req, message === "查無此訂單" ? 404 : 400, message);
    }

    // 原樣回傳資料庫欄位,另加現有前端使用的別名(由既有欄位推導,沒有新增任何資料)
    const status = typeof data.status === "string" ? data.status : "";
    return respond(req, 200, {
      ...data,
      orderNo: data.order_no,
      statusLabel: STATUS_LABEL[status] ?? status,
    });
  } catch (err) {
    console.error("get-order unexpected error:", err instanceof Error ? err.name : "unknown");
    return fail(req, 500, "系統忙碌中,請稍後再試");
  }
});
