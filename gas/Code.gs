/**
 * 煎福鍋貼 — 訂單收件 API（Google Apps Script，綁定在試算表上）
 *
 * 流程：網站 POST JSON → doPost 驗證 → 以「商品」工作表重算金額 → 寫入「訂單」「訂單明細」→ 寄通知信 → 回傳訂單編號
 * 部署：部署 → 新增部署作業 → 類型「網頁應用程式」→ 執行身分「我」→ 存取權「所有人」
 */

/* ===== 設定 ===== */
const CONFIG = {
  OWNER_EMAIL: '',            // 店家收單通知信箱（留空則不寄）
  ADMIN_KEY: '',              // 後台登入金鑰（請自訂一組夠長的隨機字串；留空則停用後台 API）
  SEND_CUSTOMER_MAIL: true,   // 顧客有填 Email 時，是否寄確認信
  SHOP_NAME: '煎福鍋貼專賣',
  SHEET_ORDERS: '訂單',
  SHEET_ITEMS: '訂單明細',
  SHEET_PRODUCTS: '商品',
  STATUSES: ['新訂單', '製作中', '待取餐', '配送中', '已完成', '已取消'],
  MAX_QTY_PER_ITEM: 50,
  MAX_ITEMS: 30
};

const FEES = {
  dine: { name: '內用', fee: s => Math.round(s * 0.1), eta: '約 15–20 分鐘' },
  take: { name: '外帶', fee: () => 0, eta: '約 15–20 分鐘' },
  ship: { name: '宅配', fee: s => (s >= 1000 ? 0 : 150), eta: '2–3 個工作天' }
};

/* ===== 一次性初始化：建立工作表、標題列、商品資料、狀態下拉 ===== */
function setup() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();

  const orders = getOrCreate_(ss, CONFIG.SHEET_ORDERS);
  orders.getRange(1, 1, 1, 14).setValues([[
    '訂單編號', '建立時間', '狀態', '取餐方式', '姓名', '手機', 'Email', '門市', '地址', '備註', '小計', '運費/服務費', '應付總額', '更新時間'
  ]]);
  orders.setFrozenRows(1);
  orders.getRange(2, 3, 998, 1).setDataValidation(
    SpreadsheetApp.newDataValidation().requireValueInList(CONFIG.STATUSES, true).build());
  orders.getRange(2, 2, 998, 1).setNumberFormat('yyyy-mm-dd hh:mm:ss');
  orders.getRange(2, 11, 998, 3).setNumberFormat('#,##0');
  orders.getRange(2, 14, 998, 1).setNumberFormat('yyyy-mm-dd hh:mm:ss');
  orders.getRange(2, 6, 998, 1).setNumberFormat('@'); // 手機保留開頭 0
  styleHeader_(orders, 14);

  const items = getOrCreate_(ss, CONFIG.SHEET_ITEMS);
  items.getRange(1, 1, 1, 6).setValues([['訂單編號', '商品ID', '品名', '單價', '數量', '小計']]);
  items.setFrozenRows(1);
  styleHeader_(items, 6);

  const prods = getOrCreate_(ss, CONFIG.SHEET_PRODUCTS);
  prods.clear();
  prods.getRange(1, 1, 1, 5).setValues([['商品ID', '品名', '單價', '分類', '上架(TRUE/FALSE)']]);
  prods.getRange(2, 1, PRODUCTS.length, 5).setValues(PRODUCTS);
  prods.setFrozenRows(1);
  styleHeader_(prods, 5);

  // 依狀態上色
  const rules = [['新訂單', '#fde68a'], ['製作中', '#fdba74'], ['待取餐', '#bbf7d0'], ['配送中', '#bae6fd'], ['已完成', '#e5e7eb'], ['已取消', '#fecaca']]
    .map(r => SpreadsheetApp.newConditionalFormatRule().whenTextEqualTo(r[0]).setBackground(r[1])
      .setRanges([orders.getRange('C2:C1000')]).build());
  orders.setConditionalFormatRules(rules);

  const def = ss.getSheetByName('工作表1') || ss.getSheetByName('Sheet1');
  if (def && ss.getSheets().length > 1) ss.deleteSheet(def);
  ss.toast('初始化完成，請接著部署為網頁應用程式。', CONFIG.SHOP_NAME, 8);
}

/* ===== 健康檢查：瀏覽器直接開部署網址會看到 ===== */
function doGet() {
  return json_({ ok: true, service: CONFIG.SHOP_NAME + ' order API', time: new Date().toISOString() });
}

/* ===== 收單 ===== */
function doPost(e) {
  const lock = LockService.getScriptLock();
  try {
    const body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (body.action === 'track') return track_(body); // 顧客查詢訂單（公開，只回品項/金額/狀態）
    if (body.action) return admin_(body, lock); // 後台管理請求（需金鑰）
    if (body.hp) return json_({ ok: true, orderNo: 'JF-IGNORED' }); // honeypot：機器人靜默略過

    const v = validate_(body);
    if (v.error) return json_({ ok: false, error: v.error });

    lock.waitLock(20000); // 避免同時下單造成編號重複
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const pricing = price_(ss, body.items, v.mode);
    if (pricing.error) return json_({ ok: false, error: pricing.error });

    const orderNo = nextOrderNo_(ss);
    const now = new Date();

    ss.getSheetByName(CONFIG.SHEET_ORDERS).appendRow([
      orderNo, now, CONFIG.STATUSES[0], FEES[v.mode].name, v.name, v.phone, v.email, v.store, v.address, v.note,
      pricing.subtotal, pricing.fee, pricing.total, now
    ]);
    const rows = pricing.lines.map(l => [orderNo, l.id, l.name, l.price, l.qty, l.price * l.qty]);
    const sh = ss.getSheetByName(CONFIG.SHEET_ITEMS);
    sh.getRange(sh.getLastRow() + 1, 1, rows.length, 6).setValues(rows);
    SpreadsheetApp.flush();

    notify_(orderNo, v, pricing);
    return json_({ ok: true, orderNo: orderNo, total: pricing.total, eta: FEES[v.mode].eta });
  } catch (err) {
    console.error(err);
    return json_({ ok: false, error: '系統忙碌中，請稍後再試' });
  } finally {
    try { lock.releaseLock(); } catch (x) {}
  }
}

/* ===== 後台管理 API：列出訂單 / 更新狀態（以 ADMIN_KEY 驗證，走 POST 避免金鑰出現在網址） ===== */
function admin_(b, lock) {
  if (!CONFIG.ADMIN_KEY || b.key !== CONFIG.ADMIN_KEY) return json_({ ok: false, error: '金鑰不正確', code: 'AUTH' });
  if (b.action === 'list') return json_({ ok: true, statuses: CONFIG.STATUSES, orders: listOrders_() });
  if (b.action === 'status') {
    if (CONFIG.STATUSES.indexOf(b.status) < 0) return json_({ ok: false, error: '狀態不正確' });
    lock.waitLock(20000);
    const sh = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(CONFIG.SHEET_ORDERS);
    const cell = sh.getRange(2, 1, Math.max(sh.getLastRow() - 1, 1), 1).createTextFinder(String(b.orderNo)).matchEntireCell(true).findNext();
    if (!cell) return json_({ ok: false, error: '找不到訂單 ' + b.orderNo });
    sh.getRange(cell.getRow(), 3).setValue(b.status);
    sh.getRange(cell.getRow(), 14).setValue(new Date());
    return json_({ ok: true, orderNo: b.orderNo, status: b.status });
  }
  return json_({ ok: false, error: '未知的操作' });
}

/* ===== 顧客查單：只憑訂單編號，且只回傳品項/金額/狀態/時間（不含姓名、手機、地址等個資） ===== */
function track_(b) {
  const no = String(b.orderNo == null ? '' : b.orderNo).trim().toUpperCase();
  if (!/^JF\d{6}-(\d{3}|DEMO)$/.test(no)) return json_({ ok: false, error: '訂單編號格式不正確（例：JF251022-001）' });
  const ss = SpreadsheetApp.getActiveSpreadsheet(), tz = ss.getSpreadsheetTimeZone();
  const sh = ss.getSheetByName(CONFIG.SHEET_ORDERS);
  if (sh.getLastRow() < 2) return json_({ ok: false, error: '查無此訂單' });
  const cell = sh.getRange(2, 1, sh.getLastRow() - 1, 1).createTextFinder(no).matchEntireCell(true).findNext();
  if (!cell) return json_({ ok: false, error: '查無此訂單' });
  const r = sh.getRange(cell.getRow(), 1, 1, 14).getValues()[0];
  const fmt = d => d instanceof Date ? Utilities.formatDate(d, tz, "yyyy-MM-dd'T'HH:mm:ss") : '';
  return json_({
    ok: true, orderNo: r[0], status: r[2], mode: r[3],
    createdAt: fmt(r[1]), updatedAt: fmt(r[13]) || fmt(r[1]),
    subtotal: r[10], fee: r[11], total: r[12], items: itemsByNo_(ss)[no] || []
  });
}

function itemsByNo_(ss) {
  const byNo = {}, ish = ss.getSheetByName(CONFIG.SHEET_ITEMS), il = ish.getLastRow();
  if (il >= 2) {
    const is = Math.max(2, il - 2999);
    ish.getRange(is, 1, il - is + 1, 6).getValues().forEach(r => {
      (byNo[r[0]] = byNo[r[0]] || []).push({ name: r[2], price: r[3], qty: r[4] });
    });
  }
  return byNo;
}

function listOrders_() {
  const ss = SpreadsheetApp.getActiveSpreadsheet(), tz = ss.getSpreadsheetTimeZone();
  const sh = ss.getSheetByName(CONFIG.SHEET_ORDERS), last = sh.getLastRow();
  if (last < 2) return [];
  const start = Math.max(2, last - 499); // 最近 500 筆
  const rows = sh.getRange(start, 1, last - start + 1, 13).getValues();
  const byNo = itemsByNo_(ss);
  return rows.reverse().map(r => ({
    orderNo: r[0], createdAt: r[1] instanceof Date ? Utilities.formatDate(r[1], tz, "yyyy-MM-dd'T'HH:mm:ss") : String(r[1]),
    status: r[2], mode: r[3], name: r[4], phone: String(r[5]), email: r[6], store: r[7], address: r[8], note: r[9],
    subtotal: r[10], fee: r[11], total: r[12], items: byNo[r[0]] || []
  }));
}

/* ===== 驗證與清理 ===== */
function validate_(b) {
  const clean = s => String(s == null ? '' : s).replace(/[\u0000-\u001f]/g, ' ').trim().slice(0, 200);
  const mode = FEES[b.mode] ? b.mode : null;
  if (!mode) return { error: '取餐方式不正確' };
  const name = clean(b.name), phone = clean(b.phone), email = clean(b.email);
  if (!name) return { error: '請填寫姓名' };
  if (!/^09\d{8}$/.test(phone)) return { error: '手機號碼格式不正確' };
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return { error: 'Email 格式不正確' };
  const address = clean(b.address);
  if (mode === 'ship' && !address) return { error: '宅配需填寫地址' };
  if (!Array.isArray(b.items) || !b.items.length || b.items.length > CONFIG.MAX_ITEMS) return { error: '購物車內容不正確' };
  return { mode, name, phone, email, address, store: mode === 'ship' ? '' : clean(b.store), note: clean(b.note) };
}

/* ===== 以商品表重算金額（不信任前端價格） ===== */
function price_(ss, items, mode) {
  const data = ss.getSheetByName(CONFIG.SHEET_PRODUCTS).getDataRange().getValues().slice(1);
  const map = {};
  data.forEach(r => { map[r[0]] = { name: r[1], price: Number(r[2]), on: r[4] === true || String(r[4]).toUpperCase() === 'TRUE' }; });
  const lines = [];
  let subtotal = 0;
  for (const it of items) {
    const p = map[it.id], qty = Math.floor(Number(it.qty));
    if (!p || !p.on) return { error: '商品「' + it.id + '」已下架或不存在' };
    if (!(qty >= 1 && qty <= CONFIG.MAX_QTY_PER_ITEM)) return { error: '商品數量不正確' };
    lines.push({ id: it.id, name: p.name, price: p.price, qty });
    subtotal += p.price * qty;
  }
  const fee = FEES[mode].fee(subtotal);
  return { lines, subtotal, fee, total: subtotal + fee };
}

/* ===== 訂單編號：JF + yyMMdd + 當日流水號 ===== */
function nextOrderNo_(ss) {
  const tz = ss.getSpreadsheetTimeZone();
  const day = Utilities.formatDate(new Date(), tz, 'yyMMdd');
  const props = PropertiesService.getScriptProperties();
  const key = 'seq_' + day;
  const n = Number(props.getProperty(key) || 0) + 1;
  props.setProperty(key, String(n));
  return 'JF' + day + '-' + ('000' + n).slice(-3);
}

/* ===== 通知信 ===== */
function notify_(orderNo, v, p) {
  const lines = p.lines.map(l => '・' + l.name + ' × ' + l.qty + '  NT$' + l.price * l.qty).join('\n');
  const summary = '訂單編號：' + orderNo + '\n取餐方式：' + FEES[v.mode].name +
    (v.store ? '\n門市：' + v.store : '') + (v.address ? '\n地址：' + v.address : '') +
    '\n\n' + lines + '\n\n小計 NT$' + p.subtotal + '\n服務費/運費 NT$' + p.fee + '\n應付總額 NT$' + p.total +
    (v.note ? '\n備註：' + v.note : '');
  try {
    if (CONFIG.OWNER_EMAIL) {
      MailApp.sendEmail(CONFIG.OWNER_EMAIL, '[新訂單] ' + orderNo + ' ' + v.name + ' NT$' + p.total,
        summary + '\n\n顧客：' + v.name + ' / ' + v.phone + (v.email ? ' / ' + v.email : ''));
    }
    if (CONFIG.SEND_CUSTOMER_MAIL && v.email) {
      MailApp.sendEmail(v.email, '【' + CONFIG.SHOP_NAME + '】訂單已建立 ' + orderNo,
        v.name + ' 您好，感謝您的訂購！\n\n' + summary + '\n\n預計時間：' + FEES[v.mode].eta + '\n如有問題請來電 (02) 2345-6789。');
    }
  } catch (err) { console.error('mail failed', err); } // 寄信失敗不影響訂單
}

/* ===== 工具 ===== */
function json_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
function getOrCreate_(ss, n) { return ss.getSheetByName(n) || ss.insertSheet(n); }
function styleHeader_(sh, cols) {
  sh.getRange(1, 1, 1, cols).setBackground('#4a2e1a').setFontColor('#fffaf2').setFontWeight('bold');
  sh.autoResizeColumns(1, cols);
}

/* ===== 商品種子資料（與網站 MENU / GIFTS 的 id 與價格一致；日後在「商品」工作表直接改價即可） ===== */
const PRODUCTS = [
  ['s1', '招牌豬肉鍋貼 (10入)', 85, '招牌鍋貼', true],
  ['s2', '韭菜豬肉鍋貼 (10入)', 90, '招牌鍋貼', true],
  ['s3', '麻辣牛肉鍋貼 (10入)', 110, '招牌鍋貼', true],
  ['s4', '起司玉米鍋貼 (10入)', 100, '招牌鍋貼', true],
  ['d1', '鮮肉水餃 (12入)', 90, '精選水餃', true],
  ['d2', '高麗菜水餃 (12入)', 85, '精選水餃', true],
  ['d3', '鮮蝦水餃 (10入)', 130, '精選水餃', true],
  ['d4', '紅油抄手 (8入)', 95, '精選水餃', true],
  ['p1', '酸辣湯', 55, '湯品/飲料', true],
  ['p2', '蛤蜊雞湯', 80, '湯品/飲料', true],
  ['p3', '古早味紅茶', 30, '湯品/飲料', true],
  ['p4', '酸梅湯', 35, '湯品/飲料', true],
  ['k1', '涼拌小黃瓜', 40, '經典小菜', true],
  ['k2', '滷味拼盤', 65, '經典小菜', true],
  ['k3', '蔥油餅', 45, '經典小菜', true],
  ['k4', '麻辣豆干', 50, '經典小菜', true],
  ['g1', '招牌招財鍋貼禮盒', 680, '冷凍禮盒', true],
  ['g2', '雙拼團圓禮盒', 820, '冷凍禮盒', true],
  ['g3', '嚐鮮綜合禮盒', 590, '冷凍禮盒', true]
];
