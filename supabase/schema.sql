-- ============================================================
-- KırtasiyePOS Faz-3: Supabase şeması (tek dükkan, 2 cihaz)
-- Kurulum: Supabase Dashboard > SQL Editor > New query > yapıştır > Run
-- Sonra: Authentication > Users > Add user (dükkan e-postası + şifre)
-- Realtime: Database > Replication > supabase_realtime'a tablolar eklenir
--           (aşağıdaki ALTER PUBLICATION satırları da yapar)
-- ============================================================

-- ---------- Sözlük tabloları ----------
create table if not exists categories (
  uuid text primary key,
  name text unique not null,
  updated_at timestamptz not null default now(),
  origin_device text not null default 'K1'
);

create table if not exists suppliers (
  uuid text primary key,
  name text not null,
  phone text,
  updated_at timestamptz not null default now(),
  origin_device text not null default 'K1'
);

-- ---------- Ürünler ----------
create table if not exists products (
  uuid text primary key,
  barcode text unique,
  name text not null,
  category_uuid text references categories(uuid) on delete set null,
  unit text not null default 'adet',
  buy_price double precision not null default 0,
  sell_price double precision not null default 0,
  kdv_rate double precision not null default 20,
  stock double precision not null default 0,
  critical_level double precision not null default 5,
  supplier_uuid text references suppliers(uuid) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  origin_device text not null default 'K1',
  is_deleted boolean not null default false
);
create index if not exists products_barcode_idx on products(barcode);
create index if not exists products_updated_idx on products(updated_at);

-- ---------- Hareketler (değişmez) ----------
create table if not exists stock_movements (
  uuid text primary key,
  product_uuid text not null references products(uuid) on delete cascade,
  type text not null,
  qty double precision not null,
  prev_stock double precision not null,
  new_stock double precision not null,
  note text,
  date timestamptz not null default now(),
  origin_device text not null default 'K1'
);
create index if not exists movements_date_idx on stock_movements(date);

-- ---------- Satışlar (değişmez) ----------
create table if not exists sales (
  uuid text primary key,
  receipt_no text unique not null,
  date timestamptz not null default now(),
  total double precision not null default 0,
  kdv_total double precision not null default 0,
  profit_total double precision not null default 0,
  discount double precision not null default 0,
  payment_type text not null default 'nakit',
  item_count integer not null default 0,
  origin_device text not null default 'K1'
);
create index if not exists sales_date_idx on sales(date);

create table if not exists sale_items (
  uuid text primary key,
  sale_uuid text not null references sales(uuid) on delete cascade,
  product_uuid text references products(uuid) on delete set null,
  barcode text,
  name text not null,
  qty double precision not null,
  unit_price double precision not null,
  kdv_rate double precision not null default 20,
  kdv_amount double precision not null default 0,
  buy_price_snapshot double precision not null default 0,
  profit double precision not null default 0
);
create index if not exists items_sale_idx on sale_items(sale_uuid);

-- ---------- Giderler (değişmez) ----------
create table if not exists expenses (
  uuid text primary key,
  date timestamptz not null default now(),
  category text not null,
  amount double precision not null,
  note text,
  updated_at timestamptz not null default now(),
  origin_device text not null default 'K1'
);
create index if not exists expenses_date_idx on expenses(date);

-- ============================================================
-- Güvenlik: giriş yapmış dükkan kullanıcısı her şeyi okur/yazar.
-- (Tek dükkan: kullanıcı = dükkan. RLS açık, anon anahtar yetmez.)
-- ============================================================
alter table categories enable row level security;
alter table suppliers enable row level security;
alter table products enable row level security;
alter table stock_movements enable row level security;
alter table sales enable row level security;
alter table sale_items enable row level security;
alter table expenses enable row level security;

drop policy if exists "auth_all" on categories;
drop policy if exists "auth_all" on suppliers;
drop policy if exists "auth_all" on products;
drop policy if exists "auth_all" on stock_movements;
drop policy if exists "auth_all" on sales;
drop policy if exists "auth_all" on sale_items;
drop policy if exists "auth_all" on expenses;

create policy "auth_all" on categories
  for all to authenticated using (true) with check (true);
create policy "auth_all" on suppliers
  for all to authenticated using (true) with check (true);
create policy "auth_all" on products
  for all to authenticated using (true) with check (true);
create policy "auth_all" on stock_movements
  for all to authenticated using (true) with check (true);
create policy "auth_all" on sales
  for all to authenticated using (true) with check (true);
create policy "auth_all" on sale_items
  for all to authenticated using (true) with check (true);
create policy "auth_all" on expenses
  for all to authenticated using (true) with check (true);

-- ---------- Realtime (karşı cihaza anlık yansıma) ----------
alter publication supabase_realtime add table
  categories, suppliers, products, stock_movements, sales, sale_items, expenses;

-- ============================================================
-- v3 eklentisi (parçalı/cari): ilk kurulumda üstteki CREATE'ler
-- zaten içerir; MEVCUT projeye sadece aşağıdakileri çalıştırın.
-- ============================================================
alter table sales add column if not exists cash_amount double precision not null default 0;
alter table sales add column if not exists card_amount double precision not null default 0;
alter table sales add column if not exists customer text not null default '';
alter table sales add column if not exists paid double precision not null default 0;
alter table sales add column if not exists updated_at timestamptz not null default now();

-- ============================================================
-- v4 eklentisi (tedarikçi defteri)
-- ============================================================
create table if not exists supplier_ledger (
  uuid text primary key,
  supplier_uuid text not null references suppliers(uuid) on delete cascade,
  date timestamptz not null default now(),
  kind text not null,
  amount double precision not null,
  note text,
  updated_at timestamptz not null default now(),
  origin_device text not null default 'K1'
);
create index if not exists ledger_supplier_idx on supplier_ledger(supplier_uuid);
create index if not exists ledger_date_idx on supplier_ledger(date);

alter table supplier_ledger enable row level security;
drop policy if exists "auth_all" on supplier_ledger;
create policy "auth_all" on supplier_ledger
  for all to authenticated using (true) with check (true);

alter publication supabase_realtime add table supplier_ledger;
