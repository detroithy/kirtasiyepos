-- ============================================================
-- KırtasiyePOS Faz-3 KURTARMA: tek seferlik, sırayla uygula.
-- Supabase Dashboard > SQL Editor > yapıştır > Run
--
-- ADIM 1: v3 kolonlarını ekle (PC'deki PGRST204 hatasının çözümü).
-- ADIM 2: Bulutu boşalt. KORKMA: satışlar/ürünler cihazlarda durur;
--         TRUNCATE sonrası önce PC, sonra telefon "Tümünü Gönder"
--         yapınca veri geri pushlanır ve kimlikler birleşir.
-- ============================================================

-- ADIM 1: v3 kolonları
alter table sales add column if not exists cash_amount double precision not null default 0;
alter table sales add column if not exists card_amount double precision not null default 0;
alter table sales add column if not exists customer text not null default '';
alter table sales add column if not exists paid double precision not null default 0;
alter table sales add column if not exists updated_at timestamptz not null default now();

-- ADIM 2: temiz eşleşme için bulutu boşalt
TRUNCATE sales, sale_items, stock_movements, expenses, products, categories, suppliers CASCADE;
