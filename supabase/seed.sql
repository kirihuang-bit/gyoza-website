-- 種子資料:來源為 index.html 的 STORES / MENU / GIFTS 與 gas/Code.gs 的 PRODUCTS
-- 圖片網址 = https://images.unsplash.com/<photo id>?auto=format&fit=crop&w=800&q=75(同前端 IMG())

insert into public.stores (id, name, address, phone, sort_order) values
  ('flag',     '旗艦店',   '台北市中正區忠孝西路一段 100 號', '(02) 2345-6789', 1),
  ('xinyi',    '信義店',   '台北市信義區松仁路 58 號 1 樓',   '(02) 8789-1234', 2),
  ('taichung', '台中勤美店', '台中市西區公益路 68 號',         '(04) 2301-5678', 3);
-- 營業時間(hours)前端目前仍寫死，未入庫:待確認是否需要

insert into public.products
  (id, name, price, category_key, category_label, description, image_url, tags, sub_label, badge, sort_order) values
('s1','招牌豬肉鍋貼 (10入)',85,'signature','招牌鍋貼','台灣豬後腿肉搭配高麗菜，薄皮冰花脆底，咬開肉汁四溢。','https://images.unsplash.com/photo-1496116218417-1a781b1c416c?auto=format&fit=crop&w=800&q=75',array['爆汁','人氣'],null,null,10),
('s2','韭菜豬肉鍋貼 (10入)',90,'signature','招牌鍋貼','現摘韭菜的清香，與鮮肉融合出傳統老味道。','https://images.unsplash.com/photo-1563245372-f21724e3856d?auto=format&fit=crop&w=800&q=75',array['經典'],null,null,20),
('s3','麻辣牛肉鍋貼 (10入)',110,'signature','招牌鍋貼','花椒與辣油提香，嗆辣過癮，下飯又下酒。','https://images.unsplash.com/photo-1534422298391-e4f8c172dddb?auto=format&fit=crop&w=800&q=75',array['辣 🌶🌶🌶','新品'],null,null,30),
('s4','起司玉米鍋貼 (10入)',100,'signature','招牌鍋貼','牽絲起司與甜玉米，孩子最愛的溫和口味。','https://images.unsplash.com/photo-1525755662778-989d0524087e?auto=format&fit=crop&w=800&q=75',array['不辣','親子'],null,null,40),
('d1','鮮肉水餃 (12入)',90,'dumpling','精選水餃','手工擀皮，Q彈有勁，湯汁飽滿。','https://images.unsplash.com/photo-1563245372-f21724e3856d?auto=format&fit=crop&w=800&q=75',array['人氣'],null,null,50),
('d2','高麗菜水餃 (12入)',85,'dumpling','精選水餃','清甜高麗菜與豬肉的完美比例。','https://images.unsplash.com/photo-1534422298391-e4f8c172dddb?auto=format&fit=crop&w=800&q=75',array['清爽'],null,null,60),
('d3','鮮蝦水餃 (10入)',130,'dumpling','精選水餃','整尾鮮蝦入餡，彈牙鮮甜。','https://images.unsplash.com/photo-1525755662778-989d0524087e?auto=format&fit=crop&w=800&q=75',array['爆汁','海鮮'],null,null,70),
('d4','紅油抄手 (8入)',95,'dumpling','精選水餃','特調紅油與蒜泥醬汁，微麻微辣。','https://images.unsplash.com/photo-1496116218417-1a781b1c416c?auto=format&fit=crop&w=800&q=75',array['辣 🌶🌶'],null,null,80),
('p1','酸辣湯',55,'soup','湯品/飲料','濃稠酸辣，豆腐、木耳、蛋花料多味美。','https://images.unsplash.com/photo-1547592166-23ac45744acd?auto=format&fit=crop&w=800&q=75',array['辣 🌶','人氣'],null,null,90),
('p2','蛤蜊雞湯',80,'soup','湯品/飲料','雞骨熬煮四小時，加入鮮蛤蜊提鮮。','https://images.unsplash.com/photo-1569718212165-3a8278d5f624?auto=format&fit=crop&w=800&q=75',array['暖心'],null,null,100),
('p3','古早味紅茶',30,'soup','湯品/飲料','台灣茶葉現泡，微甜回甘，解膩首選。','https://images.unsplash.com/photo-1556679343-c7306c1976bc?auto=format&fit=crop&w=800&q=75',array['冰/熱'],null,null,110),
('p4','酸梅湯',35,'soup','湯品/飲料','烏梅、洛神、甘草熬製，清爽解渴。','https://images.unsplash.com/photo-1556679343-c7306c1976bc?auto=format&fit=crop&w=800&q=75',array['無咖啡因'],null,null,120),
('k1','涼拌小黃瓜',40,'side','經典小菜','蒜香拍黃瓜，清脆開胃。','https://images.unsplash.com/photo-1512058564366-18510be2db19?auto=format&fit=crop&w=800&q=75',array['爽口'],null,null,130),
('k2','滷味拼盤',65,'side','經典小菜','豆干、海帶、滷蛋，老滷汁熬製入味。','https://images.unsplash.com/photo-1544025162-d76694265947?auto=format&fit=crop&w=800&q=75',array['經典'],null,null,140),
('k3','蔥油餅',45,'side','經典小菜','手工千層蔥油餅，外酥內軟，蔥香十足。','https://images.unsplash.com/photo-1534422298391-e4f8c172dddb?auto=format&fit=crop&w=800&q=75',array['人氣'],null,null,150),
('k4','麻辣豆干',50,'side','經典小菜','微辣下酒菜，嚼勁十足。','https://images.unsplash.com/photo-1544025162-d76694265947?auto=format&fit=crop&w=800&q=75',array['辣 🌶🌶'],null,null,160),
('g1','招牌招財鍋貼禮盒',680,'gift','冷凍禮盒','50 顆招牌豬肉鍋貼＋獨家沾醬 ×2，附煎鍋教學卡。','https://images.unsplash.com/photo-1496116218417-1a781b1c416c?auto=format&fit=crop&w=800&q=75','{}','50 入 · 家庭組','招牌熱銷',170),
('g2','雙拼團圓禮盒',820,'gift','冷凍禮盒','招牌豬肉 30 顆＋韭菜豬肉 30 顆，燙金紅色提盒。','https://images.unsplash.com/photo-1563245372-f21724e3856d?auto=format&fit=crop&w=800&q=75','{}','60 入 · 節慶送禮','節慶限定',180),
('g3','嚐鮮綜合禮盒',590,'gift','冷凍禮盒','四種口味各 10 顆，加贈麻辣辣油一罐。','https://images.unsplash.com/photo-1525755662778-989d0524087e?auto=format&fit=crop&w=800&q=75','{}','40 入 · 辦公室分享','新手首選',190);
