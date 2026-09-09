-- ============================================================
-- KırtasiyePOS Faz-3 KURTARMA (TAMAMLANDI — TEKRAR ÇALIŞTIRMA!
-- TRUNCATE bulutu boşaltır. Yeni kurulumlar schema.sql kullanır.)
-- ============================================================

-- ADIM 1: v3 kolonları
alter table sales add column if not exists cash_amount double precision not null default 0;
alter table sales add column if not exists card_amount double precision not null default 0;
alter table sales add column if not exists customer text not null default '';
alter table sales add column if not exists paid double precision not null default 0;
alter table sales add column if not exists updated_at timestamptz not null default now();

-- ADIM 2: temiz eşleşme için bulutu boşalt
TRUNCATE sales, sale_items, stock_movements, expenses, products, categories, suppliers, supplier_ledger CASCADE;
