-- ============================================================
-- RIFA BENEFICENTE PIRACAIA - SUPABASE + INFINITEPAY
-- 200 numeros | R$ 10 por numero | Premio R$ 200 no Pix
-- Sorteio: 18/10/2026 20:00 | Instagram @TUDODEHELENA
-- ============================================================
-- Este instalador pode ser executado novamente.
-- Ele preserva os pedidos existentes e migra o antigo status Reservado para Em pagamento.
-- ============================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;

revoke all on schema private from public;
grant usage on schema private to anon, authenticated, service_role;

create table if not exists public.raffle_numbers (
  number integer primary key check (number between 1 and 200),
  status text not null default 'available' check (status in ('available', 'pending', 'paid')),
  updated_at timestamptz not null default now()
);

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  buyer_name text not null,
  whatsapp text not null,
  numbers integer[] not null,
  payment_status text not null default 'pending' check (payment_status in ('pending', 'paid')),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

-- Migração da versão antiga: Reservado -> Em pagamento
alter table public.raffle_numbers drop constraint if exists raffle_numbers_status_check;
alter table public.reservations drop constraint if exists reservations_payment_status_check;
update public.raffle_numbers set status = 'pending' where status = 'reserved';
update public.reservations set payment_status = 'pending' where payment_status = 'reserved';
alter table public.raffle_numbers add constraint raffle_numbers_status_check check (status in ('available', 'pending', 'paid'));
alter table public.reservations add constraint reservations_payment_status_check check (payment_status in ('pending', 'paid'));

alter table public.reservations add column if not exists order_nsu text;
alter table public.reservations add column if not exists expected_amount_cents integer;
alter table public.reservations add column if not exists payment_provider text default 'infinitepay';
alter table public.reservations add column if not exists checkout_url text;
alter table public.reservations add column if not exists checkout_created_at timestamptz;
alter table public.reservations add column if not exists payment_transaction_nsu text;
alter table public.reservations add column if not exists payment_receipt_url text;
alter table public.reservations add column if not exists capture_method text;

update public.reservations
set order_nsu = 'RIFA-' || replace(gen_random_uuid()::text, '-', '')
where order_nsu is null or btrim(order_nsu) = '';

update public.reservations
set expected_amount_cents = cardinality(numbers) * 1000
where expected_amount_cents is null or expected_amount_cents <= 0;

update public.reservations
set payment_provider = 'infinitepay'
where payment_provider is null or btrim(payment_provider) = '';

alter table public.reservations alter column order_nsu set not null;
alter table public.reservations alter column expected_amount_cents set not null;
alter table public.reservations alter column payment_provider set not null;

create unique index if not exists reservations_order_nsu_uq on public.reservations(order_nsu);
create index if not exists reservations_payment_status_idx on public.reservations(payment_status);

create table if not exists public.raffle_public_state (
  id smallint primary key default 1 check (id = 1),
  sales_closed boolean not null default false,
  draw_at timestamptz not null,
  instagram_handle text not null,
  winner_number integer,
  winner_reservation_id uuid,
  drawn_at timestamptz
);

create table if not exists private.raffle_admin_secret (
  id smallint primary key default 1 check (id = 1),
  password_sha256 text not null
);

insert into public.raffle_numbers(number, status)
select n, 'available' from generate_series(1, 200) n
on conflict (number) do nothing;

insert into public.raffle_public_state(id, sales_closed, draw_at, instagram_handle)
values (1, false, '2026-10-18 20:00:00-03'::timestamptz, '@TUDODEHELENA')
on conflict (id) do nothing;

update public.raffle_public_state
set draw_at = '2026-10-18 20:00:00-03'::timestamptz,
    instagram_handle = '@TUDODEHELENA'
where id = 1;

insert into private.raffle_admin_secret(id, password_sha256)
values (1, 'ae7bb7ae82ccf7e20fcdba141716f1c2ead8757e8291033bdbf22f99a60e5e28')
on conflict (id) do update set password_sha256 = excluded.password_sha256;

-- RLS
alter table public.raffle_numbers enable row level security;
alter table public.reservations enable row level security;
alter table public.raffle_public_state enable row level security;
alter table private.raffle_admin_secret enable row level security;

revoke all on public.raffle_numbers from anon, authenticated;
revoke all on public.reservations from anon, authenticated;
revoke all on public.raffle_public_state from anon, authenticated;
grant select on public.raffle_numbers to anon, authenticated;
grant select on public.raffle_public_state to anon, authenticated;

drop policy if exists "public read raffle numbers" on public.raffle_numbers;
create policy "public read raffle numbers" on public.raffle_numbers for select to anon, authenticated using (true);

drop policy if exists "public read raffle state" on public.raffle_public_state;
create policy "public read raffle state" on public.raffle_public_state for select to anon, authenticated using (true);

-- Nome e WhatsApp nao possuem policy publica de leitura.

create or replace function private.admin_password_ok(p_password text)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, extensions
as $$
  select exists (
    select 1 from private.raffle_admin_secret s
    where s.id = 1
      and s.password_sha256 = pg_catalog.encode(
        extensions.digest(coalesce(p_password, '')::text, 'sha256'::text), 'hex'::text
      )
  );
$$;

-- Remove a rota antiga de simples reserva, caso exista de uma versão anterior.
drop function if exists public.reserve_numbers(text,text,integer[]);
drop function if exists private.reserve_numbers_internal(text,text,integer[]);

create or replace function private.start_infinitepay_payment_internal(p_name text, p_whatsapp text, p_numbers integer[])
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_numbers integer[];
  v_id uuid := gen_random_uuid();
  v_order_nsu text;
  v_total integer;
  v_amount integer;
  v_state public.raffle_public_state%rowtype;
begin
  select * into v_state from public.raffle_public_state where id = 1 for update;
  if v_state.sales_closed or now() >= v_state.draw_at then raise exception 'As vendas desta rifa estao encerradas.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 or length(trim(coalesce(p_name, ''))) > 80 then raise exception 'Digite um nome valido.'; end if;
  if coalesce(p_whatsapp, '') !~ '^[0-9]{10,15}$' then raise exception 'Digite um WhatsApp valido com DDD.'; end if;
  if coalesce(cardinality(p_numbers), 0) < 1 then raise exception 'Escolha pelo menos um numero.'; end if;

  select array_agg(distinct x order by x) into v_numbers from unnest(p_numbers) x;
  if cardinality(v_numbers) <> cardinality(p_numbers) then raise exception 'Existem numeros repetidos na selecao.'; end if;
  if exists (select 1 from unnest(v_numbers) x where x < 1 or x > 200) then raise exception 'Selecao contem numero invalido.'; end if;

  perform n.number from public.raffle_numbers n where n.number = any(v_numbers) order by n.number for update;
  select count(*) into v_total from public.raffle_numbers n where n.number = any(v_numbers);
  if v_total <> cardinality(v_numbers) then raise exception 'Um ou mais numeros nao existem.'; end if;
  if exists (select 1 from public.raffle_numbers n where n.number = any(v_numbers) and n.status <> 'available') then
    raise exception 'Um dos numeros escolhidos acabou de entrar em pagamento. Atualize e escolha outro.';
  end if;

  v_order_nsu := 'RIFA-' || replace(v_id::text, '-', '');
  v_amount := cardinality(v_numbers) * 1000;

  insert into public.reservations(
    id, buyer_name, whatsapp, numbers, payment_status,
    order_nsu, expected_amount_cents, payment_provider
  ) values (
    v_id, trim(p_name), p_whatsapp, v_numbers, 'pending',
    v_order_nsu, v_amount, 'infinitepay'
  );

  update public.raffle_numbers set status = 'pending', updated_at = now() where number = any(v_numbers);

  return jsonb_build_object(
    'ok', true,
    'order_id', v_id,
    'order_nsu', v_order_nsu,
    'amount_cents', v_amount,
    'numbers', to_jsonb(v_numbers)
  );
end;
$$;

create or replace function private.payment_status_internal(p_order_nsu text)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r public.reservations%rowtype;
begin
  select * into r from public.reservations where order_nsu = p_order_nsu;
  if r.id is null then return jsonb_build_object('found', false); end if;
  return jsonb_build_object(
    'found', true,
    'payment_status', r.payment_status,
    'numbers', to_jsonb(r.numbers),
    'expected_amount_cents', r.expected_amount_cents,
    'checkout_url', r.checkout_url,
    'receipt_url', r.payment_receipt_url,
    'capture_method', r.capture_method,
    'paid_at', r.paid_at
  );
end;
$$;

create or replace function private.confirm_infinitepay_payment_internal(
  p_order_nsu text,
  p_transaction_nsu text,
  p_receipt_url text,
  p_capture_method text,
  p_amount_cents integer
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r public.reservations%rowtype;
begin
  select * into r from public.reservations where order_nsu = p_order_nsu for update;
  if r.id is null then raise exception 'Pedido nao encontrado.'; end if;
  if r.expected_amount_cents <> p_amount_cents then raise exception 'Valor do pagamento nao corresponde ao pedido.'; end if;

  if r.payment_status = 'paid' then
    return jsonb_build_object('ok', true, 'already_paid', true, 'reservation_id', r.id);
  end if;

  update public.reservations
  set payment_status = 'paid',
      paid_at = now(),
      payment_transaction_nsu = p_transaction_nsu,
      payment_receipt_url = nullif(p_receipt_url, ''),
      capture_method = nullif(p_capture_method, '')
  where id = r.id;

  update public.raffle_numbers set status = 'paid', updated_at = now() where number = any(r.numbers);
  return jsonb_build_object('ok', true, 'reservation_id', r.id, 'numbers', to_jsonb(r.numbers));
end;
$$;

create or replace function private.cancel_infinitepay_pending_internal(p_order_nsu text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r public.reservations%rowtype;
begin
  select * into r from public.reservations where order_nsu = p_order_nsu for update;
  if r.id is null then return jsonb_build_object('ok', true, 'found', false); end if;
  if r.payment_status = 'paid' then return jsonb_build_object('ok', false, 'paid', true); end if;
  update public.raffle_numbers set status = 'available', updated_at = now() where number = any(r.numbers) and status = 'pending';
  delete from public.reservations where id = r.id and payment_status = 'pending';
  return jsonb_build_object('ok', true, 'found', true, 'released', true);
end;
$$;

create or replace function private.admin_dashboard_internal(p_password text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_result jsonb;
  v_winner_name text;
  v_winner_whatsapp text;
  v_state public.raffle_public_state%rowtype;
begin
  if not private.admin_password_ok(p_password) then raise exception 'Senha incorreta.'; end if;
  select * into v_state from public.raffle_public_state where id = 1;
  if v_state.winner_reservation_id is not null then
    select r.buyer_name, r.whatsapp into v_winner_name, v_winner_whatsapp
    from public.reservations r where r.id = v_state.winner_reservation_id;
  end if;

  select jsonb_build_object(
    'stats', jsonb_build_object(
      'available', (select count(*) from public.raffle_numbers where status = 'available'),
      'pending', (select count(*) from public.raffle_numbers where status = 'pending'),
      'paid', (select count(*) from public.raffle_numbers where status = 'paid'),
      'buyers', (select count(*) from public.reservations)
    ),
    'state', jsonb_build_object(
      'sales_closed', v_state.sales_closed, 'draw_at', v_state.draw_at,
      'instagram_handle', v_state.instagram_handle, 'winner_number', v_state.winner_number,
      'winner_name', v_winner_name, 'winner_whatsapp', v_winner_whatsapp, 'drawn_at', v_state.drawn_at
    ),
    'numbers', coalesce((select jsonb_agg(jsonb_build_object('number', n.number, 'status', n.status) order by n.number) from public.raffle_numbers n), '[]'::jsonb),
    'reservations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id, 'buyer_name', r.buyer_name, 'whatsapp', r.whatsapp,
        'numbers', to_jsonb(r.numbers), 'payment_status', r.payment_status,
        'created_at', r.created_at, 'paid_at', r.paid_at,
        'order_nsu', r.order_nsu, 'expected_amount_cents', r.expected_amount_cents,
        'payment_provider', r.payment_provider, 'checkout_url', r.checkout_url,
        'transaction_nsu', r.payment_transaction_nsu, 'receipt_url', r.payment_receipt_url,
        'capture_method', r.capture_method
      ) order by r.created_at desc) from public.reservations r
    ), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

create or replace function private.admin_set_payment_internal(p_password text, p_reservation_id uuid, p_paid boolean)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare v_numbers integer[];
begin
  if not private.admin_password_ok(p_password) then raise exception 'Senha incorreta.'; end if;
  select r.numbers into v_numbers from public.reservations r where r.id = p_reservation_id for update;
  if v_numbers is null then raise exception 'Pedido nao encontrado.'; end if;
  update public.reservations set payment_status = case when p_paid then 'paid' else 'pending' end,
    paid_at = case when p_paid then now() else null end where id = p_reservation_id;
  update public.raffle_numbers set status = case when p_paid then 'paid' else 'pending' end, updated_at = now() where number = any(v_numbers);
  return jsonb_build_object('ok', true);
end; $$;

create or replace function private.admin_cancel_reservation_internal(p_password text, p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare v_numbers integer[]; v_winner_reservation uuid;
begin
  if not private.admin_password_ok(p_password) then raise exception 'Senha incorreta.'; end if;
  select winner_reservation_id into v_winner_reservation from public.raffle_public_state where id = 1;
  if v_winner_reservation = p_reservation_id then raise exception 'O pedido vencedor nao pode ser cancelado.'; end if;
  select r.numbers into v_numbers from public.reservations r where r.id = p_reservation_id for update;
  if v_numbers is null then raise exception 'Pedido nao encontrado.'; end if;
  update public.raffle_numbers set status = 'available', updated_at = now() where number = any(v_numbers);
  delete from public.reservations where id = p_reservation_id;
  return jsonb_build_object('ok', true);
end; $$;

create or replace function private.admin_set_sales_closed_internal(p_password text, p_closed boolean)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
begin
  if not private.admin_password_ok(p_password) then raise exception 'Senha incorreta.'; end if;
  if exists (select 1 from public.raffle_public_state where id = 1 and winner_number is not null) and p_closed = false then
    raise exception 'Nao e possivel reabrir as vendas depois do sorteio oficial.';
  end if;
  update public.raffle_public_state set sales_closed = p_closed where id = 1;
  return jsonb_build_object('ok', true, 'sales_closed', p_closed);
end; $$;

create or replace function private.admin_draw_winner_internal(p_password text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare
  v_state public.raffle_public_state%rowtype;
  v_paid_numbers integer[]; v_number integer; v_reservation public.reservations%rowtype; v_index integer;
begin
  if not private.admin_password_ok(p_password) then raise exception 'Senha incorreta.'; end if;
  select * into v_state from public.raffle_public_state where id = 1 for update;
  if v_state.winner_number is not null then raise exception 'O sorteio oficial ja foi realizado.'; end if;
  if now() < v_state.draw_at then raise exception 'O sorteio oficial so sera liberado em 18/10/2026 as 20h.'; end if;
  select array_agg(number order by number) into v_paid_numbers from public.raffle_numbers where status = 'paid';
  if coalesce(cardinality(v_paid_numbers), 0) = 0 then raise exception 'Nao existem numeros pagos para sortear.'; end if;
  v_index := 1 + floor(random() * cardinality(v_paid_numbers))::integer;
  v_number := v_paid_numbers[v_index];
  select * into v_reservation from public.reservations r where r.payment_status = 'paid' and v_number = any(r.numbers) order by r.created_at limit 1;
  if v_reservation.id is null then raise exception 'Nao foi possivel localizar o comprador do numero sorteado.'; end if;
  update public.raffle_public_state set sales_closed = true, winner_number = v_number,
    winner_reservation_id = v_reservation.id, drawn_at = now() where id = 1;
  return jsonb_build_object('number', v_number, 'buyer_name', v_reservation.buyer_name, 'whatsapp', v_reservation.whatsapp, 'drawn_at', now());
end; $$;

-- Wrappers RPC
create or replace function public.start_infinitepay_payment(p_name text, p_whatsapp text, p_numbers integer[])
returns jsonb language sql security invoker set search_path = pg_catalog, extensions as $$
  select private.start_infinitepay_payment_internal(p_name, p_whatsapp, p_numbers);
$$;

create or replace function public.payment_status(p_order_nsu text)
returns jsonb language sql security invoker set search_path = pg_catalog, extensions as $$
  select private.payment_status_internal(p_order_nsu);
$$;

create or replace function public.confirm_infinitepay_payment(
  p_order_nsu text, p_transaction_nsu text, p_receipt_url text, p_capture_method text, p_amount_cents integer
)
returns jsonb language sql security invoker set search_path = pg_catalog, extensions as $$
  select private.confirm_infinitepay_payment_internal(p_order_nsu, p_transaction_nsu, p_receipt_url, p_capture_method, p_amount_cents);
$$;

create or replace function public.cancel_infinitepay_pending(p_order_nsu text)
returns jsonb language sql security invoker set search_path = pg_catalog, extensions as $$
  select private.cancel_infinitepay_pending_internal(p_order_nsu);
$$;

create or replace function public.admin_dashboard(p_password text)
returns jsonb language sql security invoker set search_path = pg_catalog, extensions as $$ select private.admin_dashboard_internal(p_password); $$;
create or replace function public.admin_set_payment(p_password text, p_reservation_id uuid, p_paid boolean)
returns jsonb language sql security invoker set search_path = pg_catalog, extensions as $$ select private.admin_set_payment_internal(p_password, p_reservation_id, p_paid); $$;
create or replace function public.admin_cancel_reservation(p_password text, p_reservation_id uuid)
returns jsonb language sql security invoker set search_path = pg_catalog, extensions as $$ select private.admin_cancel_reservation_internal(p_password, p_reservation_id); $$;
create or replace function public.admin_set_sales_closed(p_password text, p_closed boolean)
returns jsonb language sql security invoker set search_path = pg_catalog, extensions as $$ select private.admin_set_sales_closed_internal(p_password, p_closed); $$;
create or replace function public.admin_draw_winner(p_password text)
returns jsonb language sql security invoker set search_path = pg_catalog, extensions as $$ select private.admin_draw_winner_internal(p_password); $$;

-- Privilegios RPC
revoke all on function private.admin_password_ok(text) from public;
revoke all on function private.start_infinitepay_payment_internal(text,text,integer[]) from public;
revoke all on function private.payment_status_internal(text) from public;
revoke all on function private.confirm_infinitepay_payment_internal(text,text,text,text,integer) from public;
revoke all on function private.cancel_infinitepay_pending_internal(text) from public;
revoke all on function private.admin_dashboard_internal(text) from public;
revoke all on function private.admin_set_payment_internal(text,uuid,boolean) from public;
revoke all on function private.admin_cancel_reservation_internal(text,uuid) from public;
revoke all on function private.admin_set_sales_closed_internal(text,boolean) from public;
revoke all on function private.admin_draw_winner_internal(text) from public;

grant execute on function private.start_infinitepay_payment_internal(text,text,integer[]) to service_role;
grant execute on function private.payment_status_internal(text) to anon, authenticated;
grant execute on function private.confirm_infinitepay_payment_internal(text,text,text,text,integer) to service_role;
grant execute on function private.cancel_infinitepay_pending_internal(text) to service_role;
grant execute on function private.admin_dashboard_internal(text) to anon, authenticated;
grant execute on function private.admin_set_payment_internal(text,uuid,boolean) to anon, authenticated;
grant execute on function private.admin_cancel_reservation_internal(text,uuid) to anon, authenticated;
grant execute on function private.admin_set_sales_closed_internal(text,boolean) to anon, authenticated;
grant execute on function private.admin_draw_winner_internal(text) to anon, authenticated;

revoke all on function public.start_infinitepay_payment(text,text,integer[]) from public;
revoke all on function public.payment_status(text) from public;
revoke all on function public.confirm_infinitepay_payment(text,text,text,text,integer) from public;
revoke all on function public.cancel_infinitepay_pending(text) from public;
revoke all on function public.admin_dashboard(text) from public;
revoke all on function public.admin_set_payment(text,uuid,boolean) from public;
revoke all on function public.admin_cancel_reservation(text,uuid) from public;
revoke all on function public.admin_set_sales_closed(text,boolean) from public;
revoke all on function public.admin_draw_winner(text) from public;

grant execute on function public.start_infinitepay_payment(text,text,integer[]) to service_role;
grant execute on function public.payment_status(text) to anon, authenticated;
grant execute on function public.confirm_infinitepay_payment(text,text,text,text,integer) to service_role;
grant execute on function public.cancel_infinitepay_pending(text) to service_role;
grant execute on function public.admin_dashboard(text) to anon, authenticated;
grant execute on function public.admin_set_payment(text,uuid,boolean) to anon, authenticated;
grant execute on function public.admin_cancel_reservation(text,uuid) to anon, authenticated;
grant execute on function public.admin_set_sales_closed(text,boolean) to anon, authenticated;
grant execute on function public.admin_draw_winner(text) to anon, authenticated;

-- Realtime
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='raffle_numbers') then
    alter publication supabase_realtime add table public.raffle_numbers;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='raffle_public_state') then
    alter publication supabase_realtime add table public.raffle_public_state;
  end if;
end $$;

-- FIM


-- ============================================================
-- ATUALIZAÇÃO - RIFA COM INFINITEPAY + PIX PESSOAL
-- Executar uma vez no SQL Editor do Supabase.
-- Pode ser reaplicado.
-- ============================================================

alter table public.reservations
  add column if not exists expires_at timestamptz;

alter table public.reservations
  drop constraint if exists reservations_payment_status_check;

alter table public.reservations
  add constraint reservations_payment_status_check
  check (payment_status in ('pending', 'paid', 'expired'));

update public.reservations
set expires_at = case
  when payment_provider = 'personal_pix' then created_at + interval '30 minutes'
  else created_at + interval '2 hours'
end
where payment_status = 'pending'
  and expires_at is null;

create index if not exists reservations_expires_at_idx
on public.reservations(expires_at)
where payment_status = 'pending';

-- Libera automaticamente compras abandonadas.
create or replace function private.release_expired_pending_internal()
returns integer
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select id, numbers
    from public.reservations
    where payment_status = 'pending'
      and expires_at is not null
      and expires_at <= now()
    for update
  loop
    update public.raffle_numbers
    set status = 'available', updated_at = now()
    where number = any(r.numbers)
      and status = 'pending';

    update public.reservations
    set payment_status = 'expired'
    where id = r.id
      and payment_status = 'pending';

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.release_expired_pending()
returns integer
language sql
security invoker
set search_path = pg_catalog, extensions
as $$
  select private.release_expired_pending_internal();
$$;

-- Atualiza a criação do checkout InfinitePay para ter expiração.
create or replace function private.start_infinitepay_payment_internal(
  p_name text,
  p_whatsapp text,
  p_numbers integer[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_numbers integer[];
  v_id uuid := gen_random_uuid();
  v_order_nsu text;
  v_total integer;
  v_amount integer;
  v_state public.raffle_public_state%rowtype;
begin
  perform private.release_expired_pending_internal();

  select * into v_state
  from public.raffle_public_state
  where id = 1
  for update;

  if v_state.sales_closed or now() >= v_state.draw_at then
    raise exception 'As vendas desta rifa estao encerradas.';
  end if;

  if length(trim(coalesce(p_name, ''))) < 2
     or length(trim(coalesce(p_name, ''))) > 80 then
    raise exception 'Digite um nome valido.';
  end if;

  if coalesce(p_whatsapp, '') !~ '^[0-9]{10,15}$' then
    raise exception 'Digite um WhatsApp valido com DDD.';
  end if;

  if coalesce(cardinality(p_numbers), 0) < 1 then
    raise exception 'Escolha pelo menos um numero.';
  end if;

  select array_agg(distinct x order by x)
  into v_numbers
  from unnest(p_numbers) x;

  if cardinality(v_numbers) <> cardinality(p_numbers) then
    raise exception 'Existem numeros repetidos na selecao.';
  end if;

  if exists (select 1 from unnest(v_numbers) x where x < 1 or x > 200) then
    raise exception 'Selecao contem numero invalido.';
  end if;

  perform n.number
  from public.raffle_numbers n
  where n.number = any(v_numbers)
  order by n.number
  for update;

  select count(*)
  into v_total
  from public.raffle_numbers n
  where n.number = any(v_numbers);

  if v_total <> cardinality(v_numbers) then
    raise exception 'Um ou mais numeros nao existem.';
  end if;

  if exists (
    select 1
    from public.raffle_numbers n
    where n.number = any(v_numbers)
      and n.status <> 'available'
  ) then
    raise exception 'Um dos numeros escolhidos esta indisponivel. Atualize e escolha outro.';
  end if;

  v_order_nsu := 'RIFA-' || replace(v_id::text, '-', '');
  v_amount := cardinality(v_numbers) * 1000;

  insert into public.reservations(
    id, buyer_name, whatsapp, numbers, payment_status,
    order_nsu, expected_amount_cents, payment_provider, expires_at
  )
  values (
    v_id, trim(p_name), p_whatsapp, v_numbers, 'pending',
    v_order_nsu, v_amount, 'infinitepay', now() + interval '2 hours'
  );

  update public.raffle_numbers
  set status = 'pending', updated_at = now()
  where number = any(v_numbers);

  return jsonb_build_object(
    'ok', true,
    'order_id', v_id,
    'order_nsu', v_order_nsu,
    'amount_cents', v_amount,
    'numbers', to_jsonb(v_numbers),
    'expires_at', now() + interval '2 hours'
  );
end;
$$;

-- Pix pessoal: cria somente uma compra em andamento; a confirmação é manual no admin.
create or replace function private.start_personal_pix_payment_internal(
  p_name text,
  p_whatsapp text,
  p_numbers integer[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_numbers integer[];
  v_id uuid := gen_random_uuid();
  v_order_nsu text;
  v_total integer;
  v_amount integer;
  v_state public.raffle_public_state%rowtype;
begin
  perform private.release_expired_pending_internal();

  select * into v_state
  from public.raffle_public_state
  where id = 1
  for update;

  if v_state.sales_closed or now() >= v_state.draw_at then
    raise exception 'As vendas desta rifa estao encerradas.';
  end if;

  if length(trim(coalesce(p_name, ''))) < 2
     or length(trim(coalesce(p_name, ''))) > 80 then
    raise exception 'Digite um nome valido.';
  end if;

  if coalesce(p_whatsapp, '') !~ '^[0-9]{10,15}$' then
    raise exception 'Digite um WhatsApp valido com DDD.';
  end if;

  if coalesce(cardinality(p_numbers), 0) < 1 then
    raise exception 'Escolha pelo menos um numero.';
  end if;

  select array_agg(distinct x order by x)
  into v_numbers
  from unnest(p_numbers) x;

  if cardinality(v_numbers) <> cardinality(p_numbers) then
    raise exception 'Existem numeros repetidos na selecao.';
  end if;

  if exists (select 1 from unnest(v_numbers) x where x < 1 or x > 200) then
    raise exception 'Selecao contem numero invalido.';
  end if;

  perform n.number
  from public.raffle_numbers n
  where n.number = any(v_numbers)
  order by n.number
  for update;

  select count(*)
  into v_total
  from public.raffle_numbers n
  where n.number = any(v_numbers);

  if v_total <> cardinality(v_numbers) then
    raise exception 'Um ou mais numeros nao existem.';
  end if;

  if exists (
    select 1
    from public.raffle_numbers n
    where n.number = any(v_numbers)
      and n.status <> 'available'
  ) then
    raise exception 'Um dos numeros escolhidos esta indisponivel. Atualize e escolha outro.';
  end if;

  v_order_nsu := 'PIX-' || replace(v_id::text, '-', '');
  v_amount := cardinality(v_numbers) * 1000;

  insert into public.reservations(
    id, buyer_name, whatsapp, numbers, payment_status,
    order_nsu, expected_amount_cents, payment_provider, expires_at
  )
  values (
    v_id, trim(p_name), p_whatsapp, v_numbers, 'pending',
    v_order_nsu, v_amount, 'personal_pix', now() + interval '30 minutes'
  );

  update public.raffle_numbers
  set status = 'pending', updated_at = now()
  where number = any(v_numbers);

  return jsonb_build_object(
    'ok', true,
    'order_id', v_id,
    'order_nsu', v_order_nsu,
    'amount_cents', v_amount,
    'numbers', to_jsonb(v_numbers),
    'expires_at', now() + interval '30 minutes'
  );
end;
$$;

-- Ao tocar no botão do WhatsApp, amplia o prazo para o organizador conferir.
create or replace function private.personal_pix_contacted_internal(p_order_nsu text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r public.reservations%rowtype;
begin
  select *
  into r
  from public.reservations
  where order_nsu = p_order_nsu
  for update;

  if r.id is null then
    raise exception 'Pedido nao encontrado.';
  end if;

  if r.payment_provider <> 'personal_pix' then
    raise exception 'Este pedido nao e Pix pessoal.';
  end if;

  if r.payment_status <> 'pending' then
    return jsonb_build_object('ok', true, 'status', r.payment_status);
  end if;

  update public.reservations
  set expires_at = now() + interval '2 hours'
  where id = r.id;

  return jsonb_build_object('ok', true, 'expires_at', now() + interval '2 hours');
end;
$$;

create or replace function public.start_personal_pix_payment(
  p_name text,
  p_whatsapp text,
  p_numbers integer[]
)
returns jsonb
language sql
security invoker
set search_path = pg_catalog, extensions
as $$
  select private.start_personal_pix_payment_internal(p_name, p_whatsapp, p_numbers);
$$;

create or replace function public.personal_pix_contacted(p_order_nsu text)
returns jsonb
language sql
security invoker
set search_path = pg_catalog, extensions
as $$
  select private.personal_pix_contacted_internal(p_order_nsu);
$$;

-- Status público do próprio pedido.
create or replace function private.payment_status_internal(p_order_nsu text)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r public.reservations%rowtype;
begin
  select *
  into r
  from public.reservations
  where order_nsu = p_order_nsu;

  if r.id is null then
    return jsonb_build_object('found', false);
  end if;

  return jsonb_build_object(
    'found', true,
    'payment_status', r.payment_status,
    'payment_provider', r.payment_provider,
    'numbers', to_jsonb(r.numbers),
    'expected_amount_cents', r.expected_amount_cents,
    'checkout_url', r.checkout_url,
    'receipt_url', r.payment_receipt_url,
    'capture_method', r.capture_method,
    'paid_at', r.paid_at,
    'expires_at', r.expires_at
  );
end;
$$;

-- Dashboard com método e expiração.
create or replace function private.admin_dashboard_internal(p_password text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_result jsonb;
  v_winner_name text;
  v_winner_whatsapp text;
  v_state public.raffle_public_state%rowtype;
begin
  if not private.admin_password_ok(p_password) then
    raise exception 'Senha incorreta.';
  end if;

  perform private.release_expired_pending_internal();

  select * into v_state
  from public.raffle_public_state
  where id = 1;

  if v_state.winner_reservation_id is not null then
    select r.buyer_name, r.whatsapp
    into v_winner_name, v_winner_whatsapp
    from public.reservations r
    where r.id = v_state.winner_reservation_id;
  end if;

  select jsonb_build_object(
    'stats', jsonb_build_object(
      'available', (select count(*) from public.raffle_numbers where status = 'available'),
      'pending', (select count(*) from public.raffle_numbers where status = 'pending'),
      'paid', (select count(*) from public.raffle_numbers where status = 'paid'),
      'buyers', (select count(*) from public.reservations where payment_status <> 'expired')
    ),
    'state', jsonb_build_object(
      'sales_closed', v_state.sales_closed,
      'draw_at', v_state.draw_at,
      'instagram_handle', v_state.instagram_handle,
      'winner_number', v_state.winner_number,
      'winner_name', v_winner_name,
      'winner_whatsapp', v_winner_whatsapp,
      'drawn_at', v_state.drawn_at
    ),
    'numbers', coalesce((
      select jsonb_agg(
        jsonb_build_object('number', n.number, 'status', n.status)
        order by n.number
      )
      from public.raffle_numbers n
    ), '[]'::jsonb),
    'reservations', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', r.id,
          'buyer_name', r.buyer_name,
          'whatsapp', r.whatsapp,
          'numbers', to_jsonb(r.numbers),
          'payment_status', r.payment_status,
          'created_at', r.created_at,
          'paid_at', r.paid_at,
          'order_nsu', r.order_nsu,
          'expected_amount_cents', r.expected_amount_cents,
          'payment_provider', r.payment_provider,
          'checkout_url', r.checkout_url,
          'transaction_nsu', r.payment_transaction_nsu,
          'receipt_url', r.payment_receipt_url,
          'capture_method', r.capture_method,
          'expires_at', r.expires_at
        )
        order by r.created_at desc
      )
      from public.reservations r
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

-- Permite confirmar manualmente Pix pessoal inclusive após expiração,
-- desde que os números ainda estejam livres.
create or replace function private.admin_set_payment_internal(
  p_password text,
  p_reservation_id uuid,
  p_paid boolean
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r public.reservations%rowtype;
begin
  if not private.admin_password_ok(p_password) then
    raise exception 'Senha incorreta.';
  end if;

  select *
  into r
  from public.reservations
  where id = p_reservation_id
  for update;

  if r.id is null then
    raise exception 'Pedido nao encontrado.';
  end if;

  if p_paid then
    if r.payment_status = 'expired' and exists (
      select 1
      from public.raffle_numbers n
      where n.number = any(r.numbers)
        and n.status <> 'available'
    ) then
      raise exception 'Este pedido expirou e pelo menos um numero ja foi usado por outra compra.';
    end if;

    update public.raffle_numbers
    set status = 'paid', updated_at = now()
    where number = any(r.numbers);

    update public.reservations
    set payment_status = 'paid',
        paid_at = now(),
        expires_at = null,
        capture_method = case
          when payment_provider = 'personal_pix' then 'pix_pessoal'
          else capture_method
        end
    where id = r.id;
  else
    update public.raffle_numbers
    set status = 'pending', updated_at = now()
    where number = any(r.numbers);

    update public.reservations
    set payment_status = 'pending',
        paid_at = null,
        expires_at = now() + interval '2 hours'
    where id = r.id;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

-- Privilégios
revoke all on function private.release_expired_pending_internal() from public;
revoke all on function private.start_personal_pix_payment_internal(text,text,integer[]) from public;
revoke all on function private.personal_pix_contacted_internal(text) from public;

grant execute on function private.release_expired_pending_internal() to anon, authenticated, service_role;
grant execute on function private.start_personal_pix_payment_internal(text,text,integer[]) to service_role;
grant execute on function private.personal_pix_contacted_internal(text) to service_role;

revoke all on function public.release_expired_pending() from public;
revoke all on function public.start_personal_pix_payment(text,text,integer[]) from public;
revoke all on function public.personal_pix_contacted(text) from public;

grant execute on function public.release_expired_pending() to anon, authenticated;
grant execute on function public.start_personal_pix_payment(text,text,integer[]) to service_role;
grant execute on function public.personal_pix_contacted(text) to service_role;

-- Libera agora os pedidos de teste antigos que já passaram do prazo.
select public.release_expired_pending();


-- ============================================================
-- CORREÇÃO: NÃO DEIXAR PIX PESSOAL PRENDER NÚMERO
-- Execute TODO este arquivo no SQL Editor do Supabase.
--
-- Regra:
-- - Pix pessoal segura o número por no máximo 10 minutos.
-- - Se a pessoa tocar em "Já paguei / enviar WhatsApp", o prazo
--   passa a 30 minutos para conferência.
-- - Se desistir, o botão "liberar números" solta imediatamente.
-- ============================================================

-- Ajusta pedidos Pix pessoal que já estão pendentes.
update public.reservations
set expires_at = least(
  coalesce(expires_at, created_at + interval '10 minutes'),
  created_at + interval '10 minutes'
)
where payment_status = 'pending'
  and payment_provider = 'personal_pix';

-- Criação do Pix pessoal: apenas 10 minutos de bloqueio técnico.
create or replace function private.start_personal_pix_payment_internal(
  p_name text,
  p_whatsapp text,
  p_numbers integer[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_numbers integer[];
  v_id uuid := gen_random_uuid();
  v_order_nsu text;
  v_total integer;
  v_amount integer;
  v_state public.raffle_public_state%rowtype;
  v_expires timestamptz := now() + interval '10 minutes';
begin
  perform private.release_expired_pending_internal();

  select * into v_state
  from public.raffle_public_state
  where id = 1
  for update;

  if v_state.sales_closed or now() >= v_state.draw_at then
    raise exception 'As vendas desta rifa estao encerradas.';
  end if;

  if length(trim(coalesce(p_name, ''))) < 2
     or length(trim(coalesce(p_name, ''))) > 80 then
    raise exception 'Digite um nome valido.';
  end if;

  if coalesce(p_whatsapp, '') !~ '^[0-9]{10,15}$' then
    raise exception 'Digite um WhatsApp valido com DDD.';
  end if;

  if coalesce(cardinality(p_numbers), 0) < 1 then
    raise exception 'Escolha pelo menos um numero.';
  end if;

  select array_agg(distinct x order by x)
  into v_numbers
  from unnest(p_numbers) x;

  if cardinality(v_numbers) <> cardinality(p_numbers) then
    raise exception 'Existem numeros repetidos na selecao.';
  end if;

  if exists (select 1 from unnest(v_numbers) x where x < 1 or x > 200) then
    raise exception 'Selecao contem numero invalido.';
  end if;

  perform n.number
  from public.raffle_numbers n
  where n.number = any(v_numbers)
  order by n.number
  for update;

  select count(*) into v_total
  from public.raffle_numbers n
  where n.number = any(v_numbers);

  if v_total <> cardinality(v_numbers) then
    raise exception 'Um ou mais numeros nao existem.';
  end if;

  if exists (
    select 1
    from public.raffle_numbers n
    where n.number = any(v_numbers)
      and n.status <> 'available'
  ) then
    raise exception 'Um dos numeros escolhidos esta indisponivel. Atualize e escolha outro.';
  end if;

  v_order_nsu := 'PIX-' || replace(v_id::text, '-', '');
  v_amount := cardinality(v_numbers) * 1000;

  insert into public.reservations(
    id, buyer_name, whatsapp, numbers, payment_status,
    order_nsu, expected_amount_cents, payment_provider, expires_at
  )
  values (
    v_id, trim(p_name), p_whatsapp, v_numbers, 'pending',
    v_order_nsu, v_amount, 'personal_pix', v_expires
  );

  update public.raffle_numbers
  set status = 'pending', updated_at = now()
  where number = any(v_numbers);

  return jsonb_build_object(
    'ok', true,
    'order_id', v_id,
    'order_nsu', v_order_nsu,
    'amount_cents', v_amount,
    'numbers', to_jsonb(v_numbers),
    'expires_at', v_expires
  );
end;
$$;

-- Ao informar que pagou e abrir o WhatsApp, dá 30 min para conferência.
create or replace function private.personal_pix_contacted_internal(p_order_nsu text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r public.reservations%rowtype;
  v_expires timestamptz := now() + interval '30 minutes';
begin
  perform private.release_expired_pending_internal();

  select * into r
  from public.reservations
  where order_nsu = p_order_nsu
  for update;

  if r.id is null then
    raise exception 'Pedido nao encontrado.';
  end if;

  if r.payment_provider <> 'personal_pix' then
    raise exception 'Este pedido nao e Pix pessoal.';
  end if;

  if r.payment_status <> 'pending' then
    return jsonb_build_object('ok', true, 'status', r.payment_status);
  end if;

  update public.reservations
  set expires_at = v_expires
  where id = r.id;

  return jsonb_build_object('ok', true, 'expires_at', v_expires);
end;
$$;

-- Cancelamento imediato pelo próprio comprador.
create or replace function private.cancel_personal_pix_pending_internal(p_order_nsu text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r public.reservations%rowtype;
begin
  select * into r
  from public.reservations
  where order_nsu = p_order_nsu
  for update;

  if r.id is null then
    return jsonb_build_object('ok', true, 'found', false);
  end if;

  if r.payment_provider <> 'personal_pix' then
    raise exception 'Este pedido nao e Pix pessoal.';
  end if;

  if r.payment_status = 'paid' then
    raise exception 'Este pagamento ja foi confirmado.';
  end if;

  if r.payment_status = 'pending' then
    update public.raffle_numbers
    set status = 'available', updated_at = now()
    where number = any(r.numbers)
      and status = 'pending';

    update public.reservations
    set payment_status = 'expired',
        expires_at = now()
    where id = r.id;
  end if;

  return jsonb_build_object('ok', true, 'found', true, 'released', true);
end;
$$;

create or replace function public.cancel_personal_pix_pending(p_order_nsu text)
returns jsonb
language sql
security invoker
set search_path = pg_catalog, extensions
as $$
  select private.cancel_personal_pix_pending_internal(p_order_nsu);
$$;

revoke all on function private.cancel_personal_pix_pending_internal(text) from public;
grant execute on function private.cancel_personal_pix_pending_internal(text) to service_role;

revoke all on function public.cancel_personal_pix_pending(text) from public;
grant execute on function public.cancel_personal_pix_pending(text) to service_role;

-- Libera imediatamente qualquer pedido antigo cujo novo prazo já venceu.
select public.release_expired_pending();


-- ============================================================
-- ADMIN PWA + SESSAO LEMBRADA + REATIVAR PEDIDOS EXPIRADOS
-- Execute TODO este arquivo no SQL Editor do Supabase.
-- Pode ser reaplicado.
-- ============================================================

create table if not exists private.raffle_admin_sessions (
  token_sha256 text primary key,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null
);

alter table private.raffle_admin_sessions enable row level security;
revoke all on private.raffle_admin_sessions from public, anon, authenticated;

create or replace function private.admin_session_ok(p_session_token text)
returns boolean language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare v_hash text;
begin
  if coalesce(p_session_token, '') = '' then return false; end if;
  delete from private.raffle_admin_sessions where expires_at <= now();
  v_hash := encode(extensions.digest(p_session_token::text, 'sha256'::text), 'hex');
  update private.raffle_admin_sessions
  set last_seen_at = now(), expires_at = now() + interval '180 days'
  where token_sha256 = v_hash and expires_at > now();
  return found;
end; $$;

create or replace function public.admin_login_session(p_password text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare v_token text; v_hash text; v_expires timestamptz := now() + interval '180 days';
begin
  if not private.admin_password_ok(p_password) then raise exception 'Senha incorreta.'; end if;
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_hash := encode(extensions.digest(v_token::text, 'sha256'::text), 'hex');
  insert into private.raffle_admin_sessions(token_sha256,created_at,last_seen_at,expires_at)
  values(v_hash,now(),now(),v_expires);
  return jsonb_build_object('ok',true,'session_token',v_token,'expires_at',v_expires);
end; $$;

create or replace function public.admin_logout_session(p_session_token text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare v_hash text;
begin
  if coalesce(p_session_token,'') <> '' then
    v_hash := encode(extensions.digest(p_session_token::text,'sha256'::text),'hex');
    delete from private.raffle_admin_sessions where token_sha256=v_hash;
  end if;
  return jsonb_build_object('ok',true);
end; $$;

create or replace function public.admin_dashboard_session(p_session_token text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare v_result jsonb; v_winner_name text; v_winner_whatsapp text; v_state public.raffle_public_state%rowtype;
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  perform private.release_expired_pending_internal();
  select * into v_state from public.raffle_public_state where id=1;
  if v_state.winner_reservation_id is not null then
    select r.buyer_name,r.whatsapp into v_winner_name,v_winner_whatsapp
    from public.reservations r where r.id=v_state.winner_reservation_id;
  end if;
  select jsonb_build_object(
    'stats',jsonb_build_object(
      'available',(select count(*) from public.raffle_numbers where status='available'),
      'pending',(select count(*) from public.raffle_numbers where status='pending'),
      'paid',(select count(*) from public.raffle_numbers where status='paid'),
      'buyers',(select count(*) from public.reservations where payment_status <> 'expired')
    ),
    'state',jsonb_build_object(
      'sales_closed',v_state.sales_closed,'draw_at',v_state.draw_at,
      'instagram_handle',v_state.instagram_handle,'winner_number',v_state.winner_number,
      'winner_name',v_winner_name,'winner_whatsapp',v_winner_whatsapp,'drawn_at',v_state.drawn_at
    ),
    'numbers',coalesce((select jsonb_agg(jsonb_build_object('number',n.number,'status',n.status) order by n.number) from public.raffle_numbers n),'[]'::jsonb),
    'reservations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',r.id,'buyer_name',r.buyer_name,'whatsapp',r.whatsapp,'numbers',to_jsonb(r.numbers),
      'payment_status',r.payment_status,'created_at',r.created_at,'paid_at',r.paid_at,'order_nsu',r.order_nsu,
      'expected_amount_cents',r.expected_amount_cents,'payment_provider',r.payment_provider,'checkout_url',r.checkout_url,
      'transaction_nsu',r.payment_transaction_nsu,'receipt_url',r.payment_receipt_url,'capture_method',r.capture_method,
      'expires_at',r.expires_at) order by r.created_at desc) from public.reservations r),'[]'::jsonb)
  ) into v_result;
  return v_result;
end; $$;

create or replace function public.admin_set_payment_session(p_session_token text,p_reservation_id uuid,p_paid boolean)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare r public.reservations%rowtype; v_conflicts integer[];
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  perform private.release_expired_pending_internal();
  select * into r from public.reservations where id=p_reservation_id for update;
  if r.id is null then raise exception 'Pedido nao encontrado.'; end if;
  if p_paid then
    if r.payment_status='expired' then
      select array_agg(n.number order by n.number) into v_conflicts
      from public.raffle_numbers n where n.number=any(r.numbers) and n.status <> 'available';
      if coalesce(cardinality(v_conflicts),0)>0 then
        raise exception 'Nao foi possivel confirmar. Numeros ja usados por outra compra: %',array_to_string(v_conflicts,', ');
      end if;
    end if;
    update public.raffle_numbers set status='paid',updated_at=now() where number=any(r.numbers);
    update public.reservations set payment_status='paid',paid_at=now(),expires_at=null,
      capture_method=case when payment_provider='personal_pix' then 'pix_pessoal' else capture_method end
      where id=r.id;
  else
    update public.raffle_numbers set status='pending',updated_at=now() where number=any(r.numbers);
    update public.reservations set payment_status='pending',paid_at=null,expires_at=now()+interval '2 hours' where id=r.id;
  end if;
  return jsonb_build_object('ok',true);
end; $$;

create or replace function public.admin_reactivate_expired_session(p_session_token text,p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare r public.reservations%rowtype; v_conflicts integer[]; v_expires timestamptz := now()+interval '2 hours';
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  perform private.release_expired_pending_internal();
  select * into r from public.reservations where id=p_reservation_id for update;
  if r.id is null then raise exception 'Pedido nao encontrado.'; end if;
  if r.payment_status <> 'expired' then raise exception 'Somente pedidos expirados podem ser reativados.'; end if;
  select array_agg(n.number order by n.number) into v_conflicts
  from public.raffle_numbers n where n.number=any(r.numbers) and n.status <> 'available';
  if coalesce(cardinality(v_conflicts),0)>0 then
    raise exception 'Nao foi possivel reativar. Numeros ja usados por outra compra: %',array_to_string(v_conflicts,', ');
  end if;
  update public.raffle_numbers set status='pending',updated_at=now() where number=any(r.numbers);
  update public.reservations set payment_status='pending',paid_at=null,expires_at=v_expires where id=r.id;
  return jsonb_build_object('ok',true,'expires_at',v_expires,'numbers',to_jsonb(r.numbers));
end; $$;

create or replace function public.admin_cancel_reservation_session(p_session_token text,p_reservation_id uuid)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare v_numbers integer[]; v_winner_reservation uuid;
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  select winner_reservation_id into v_winner_reservation from public.raffle_public_state where id=1;
  if v_winner_reservation=p_reservation_id then raise exception 'O pedido vencedor nao pode ser cancelado.'; end if;
  select r.numbers into v_numbers from public.reservations r where r.id=p_reservation_id for update;
  if v_numbers is null then raise exception 'Pedido nao encontrado.'; end if;
  update public.raffle_numbers set status='available',updated_at=now() where number=any(v_numbers);
  delete from public.reservations where id=p_reservation_id;
  return jsonb_build_object('ok',true);
end; $$;

create or replace function public.admin_set_sales_closed_session(p_session_token text,p_closed boolean)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  if exists(select 1 from public.raffle_public_state where id=1 and winner_number is not null) and p_closed=false then
    raise exception 'Nao e possivel reabrir as vendas depois do sorteio oficial.';
  end if;
  update public.raffle_public_state set sales_closed=p_closed where id=1;
  return jsonb_build_object('ok',true,'sales_closed',p_closed);
end; $$;

create or replace function public.admin_draw_winner_session(p_session_token text)
returns jsonb language plpgsql security definer set search_path = pg_catalog, extensions as $$
declare v_state public.raffle_public_state%rowtype; v_paid_numbers integer[]; v_number integer; v_reservation public.reservations%rowtype; v_index integer;
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  select * into v_state from public.raffle_public_state where id=1 for update;
  if v_state.winner_number is not null then raise exception 'O sorteio oficial ja foi realizado.'; end if;
  if now()<v_state.draw_at then raise exception 'O sorteio oficial so sera liberado em 18/10/2026 as 20h.'; end if;
  select array_agg(number order by number) into v_paid_numbers from public.raffle_numbers where status='paid';
  if coalesce(cardinality(v_paid_numbers),0)=0 then raise exception 'Nao existem numeros pagos para sortear.'; end if;
  v_index:=1+floor(random()*cardinality(v_paid_numbers))::integer; v_number:=v_paid_numbers[v_index];
  select * into v_reservation from public.reservations r where r.payment_status='paid' and v_number=any(r.numbers) order by r.created_at limit 1;
  if v_reservation.id is null then raise exception 'Nao foi possivel localizar o comprador do numero sorteado.'; end if;
  update public.raffle_public_state set sales_closed=true,winner_number=v_number,winner_reservation_id=v_reservation.id,drawn_at=now() where id=1;
  return jsonb_build_object('number',v_number,'buyer_name',v_reservation.buyer_name,'whatsapp',v_reservation.whatsapp,'drawn_at',now());
end; $$;

revoke all on function private.admin_session_ok(text) from public;
grant execute on function private.admin_session_ok(text) to anon, authenticated;
revoke all on function public.admin_login_session(text) from public;
revoke all on function public.admin_logout_session(text) from public;
revoke all on function public.admin_dashboard_session(text) from public;
revoke all on function public.admin_set_payment_session(text,uuid,boolean) from public;
revoke all on function public.admin_reactivate_expired_session(text,uuid) from public;
revoke all on function public.admin_cancel_reservation_session(text,uuid) from public;
revoke all on function public.admin_set_sales_closed_session(text,boolean) from public;
revoke all on function public.admin_draw_winner_session(text) from public;
grant execute on function public.admin_login_session(text) to anon, authenticated;
grant execute on function public.admin_logout_session(text) to anon, authenticated;
grant execute on function public.admin_dashboard_session(text) to anon, authenticated;
grant execute on function public.admin_set_payment_session(text,uuid,boolean) to anon, authenticated;
grant execute on function public.admin_reactivate_expired_session(text,uuid) to anon, authenticated;
grant execute on function public.admin_cancel_reservation_session(text,uuid) to anon, authenticated;
grant execute on function public.admin_set_sales_closed_session(text,boolean) to anon, authenticated;
grant execute on function public.admin_draw_winner_session(text) to anon, authenticated;


-- ============================================================
-- PIX PESSOAL 100% MANUAL PELO ADMIN
-- ============================================================

update public.reservations
set expires_at = null
where payment_provider = 'personal_pix'
  and payment_status = 'pending';

create or replace function private.start_personal_pix_payment_internal(
  p_name text,
  p_whatsapp text,
  p_numbers integer[]
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_numbers integer[];
  v_id uuid := gen_random_uuid();
  v_order_nsu text;
  v_total integer;
  v_amount integer;
  v_state public.raffle_public_state%rowtype;
begin
  perform private.release_expired_pending_internal();
  select * into v_state from public.raffle_public_state where id = 1 for update;
  if v_state.sales_closed or now() >= v_state.draw_at then raise exception 'As vendas desta rifa estao encerradas.'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 or length(trim(coalesce(p_name, ''))) > 80 then raise exception 'Digite um nome valido.'; end if;
  if coalesce(p_whatsapp, '') !~ '^[0-9]{10,15}$' then raise exception 'Digite um WhatsApp valido com DDD.'; end if;
  if coalesce(cardinality(p_numbers), 0) < 1 then raise exception 'Escolha pelo menos um numero.'; end if;
  select array_agg(distinct x order by x) into v_numbers from unnest(p_numbers) x;
  if cardinality(v_numbers) <> cardinality(p_numbers) then raise exception 'Existem numeros repetidos na selecao.'; end if;
  if exists (select 1 from unnest(v_numbers) x where x < 1 or x > 200) then raise exception 'Selecao contem numero invalido.'; end if;
  perform n.number from public.raffle_numbers n where n.number = any(v_numbers) order by n.number for update;
  select count(*) into v_total from public.raffle_numbers n where n.number = any(v_numbers);
  if v_total <> cardinality(v_numbers) then raise exception 'Um ou mais numeros nao existem.'; end if;
  if exists (select 1 from public.raffle_numbers n where n.number = any(v_numbers) and n.status <> 'available') then
    raise exception 'Um dos numeros escolhidos esta indisponivel. Atualize e escolha outro.';
  end if;
  v_order_nsu := 'PIX-' || replace(v_id::text, '-', '');
  v_amount := cardinality(v_numbers) * 1000;
  insert into public.reservations(id,buyer_name,whatsapp,numbers,payment_status,order_nsu,expected_amount_cents,payment_provider,expires_at)
  values(v_id,trim(p_name),p_whatsapp,v_numbers,'pending',v_order_nsu,v_amount,'personal_pix',null);
  update public.raffle_numbers set status='pending',updated_at=now() where number = any(v_numbers);
  return jsonb_build_object('ok',true,'order_id',v_id,'order_nsu',v_order_nsu,'amount_cents',v_amount,'numbers',to_jsonb(v_numbers),'expires_at',null);
end;
$$;

create or replace function private.personal_pix_contacted_internal(p_order_nsu text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare r public.reservations%rowtype;
begin
  select * into r from public.reservations where order_nsu=p_order_nsu;
  if r.id is null then raise exception 'Pedido nao encontrado.'; end if;
  if r.payment_provider <> 'personal_pix' then raise exception 'Este pedido nao e Pix pessoal.'; end if;
  return jsonb_build_object('ok',true,'status',r.payment_status,'expires_at',null);
end;
$$;

create or replace function public.admin_set_payment_session(p_session_token text,p_reservation_id uuid,p_paid boolean)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare r public.reservations%rowtype; v_conflicts integer[];
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  perform private.release_expired_pending_internal();
  select * into r from public.reservations where id=p_reservation_id for update;
  if r.id is null then raise exception 'Pedido nao encontrado.'; end if;
  if p_paid then
    if r.payment_status='expired' then
      select array_agg(n.number order by n.number) into v_conflicts from public.raffle_numbers n where n.number=any(r.numbers) and n.status<>'available';
      if coalesce(cardinality(v_conflicts),0)>0 then raise exception 'Nao foi possivel confirmar. Numeros ja usados por outra compra: %',array_to_string(v_conflicts,', '); end if;
    end if;
    update public.raffle_numbers set status='paid',updated_at=now() where number=any(r.numbers);
    update public.reservations set payment_status='paid',paid_at=now(),expires_at=null,
      capture_method=case when payment_provider='personal_pix' then 'pix_pessoal' else capture_method end where id=r.id;
  else
    update public.raffle_numbers set status='pending',updated_at=now() where number=any(r.numbers);
    update public.reservations set payment_status='pending',paid_at=null,
      expires_at=case when payment_provider='personal_pix' then null else now()+interval '2 hours' end where id=r.id;
  end if;
  return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.admin_reactivate_expired_session(text,uuid) from public;
drop function if exists public.admin_reactivate_expired_session(text,uuid);
revoke all on function public.cancel_personal_pix_pending(text) from public;
drop function if exists public.cancel_personal_pix_pending(text);
revoke all on function private.cancel_personal_pix_pending_internal(text) from public;
drop function if exists private.cancel_personal_pix_pending_internal(text);


-- ============================================================
-- ADMIN: WHATSAPP DE CONFIRMACAO - USO UNICO
-- Execute UMA VEZ no SQL Editor do Supabase.
-- Requer a versao anterior com sessao do Admin ja instalada.
-- ============================================================

alter table public.reservations
add column if not exists confirmation_whatsapp_sent_at timestamptz;

comment on column public.reservations.confirmation_whatsapp_sent_at is
'Momento em que o Admin confirmou a abertura da mensagem de pagamento no WhatsApp. Uso unico por pedido.';

create or replace function public.admin_dashboard_session(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_result jsonb;
  v_winner_name text;
  v_winner_whatsapp text;
  v_state public.raffle_public_state%rowtype;
begin
  if not private.admin_session_ok(p_session_token) then
    raise exception 'Sessao administrativa invalida ou expirada.';
  end if;

  perform private.release_expired_pending_internal();

  select * into v_state
  from public.raffle_public_state
  where id = 1;

  if v_state.winner_reservation_id is not null then
    select r.buyer_name, r.whatsapp
    into v_winner_name, v_winner_whatsapp
    from public.reservations r
    where r.id = v_state.winner_reservation_id;
  end if;

  select jsonb_build_object(
    'stats', jsonb_build_object(
      'available', (select count(*) from public.raffle_numbers where status = 'available'),
      'pending', (select count(*) from public.raffle_numbers where status = 'pending'),
      'paid', (select count(*) from public.raffle_numbers where status = 'paid'),
      'buyers', (select count(*) from public.reservations where payment_status <> 'expired')
    ),
    'state', jsonb_build_object(
      'sales_closed', v_state.sales_closed,
      'draw_at', v_state.draw_at,
      'instagram_handle', v_state.instagram_handle,
      'winner_number', v_state.winner_number,
      'winner_name', v_winner_name,
      'winner_whatsapp', v_winner_whatsapp,
      'drawn_at', v_state.drawn_at
    ),
    'numbers', coalesce((
      select jsonb_agg(
        jsonb_build_object('number', n.number, 'status', n.status)
        order by n.number
      )
      from public.raffle_numbers n
    ), '[]'::jsonb),
    'reservations', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', r.id,
          'buyer_name', r.buyer_name,
          'whatsapp', r.whatsapp,
          'numbers', to_jsonb(r.numbers),
          'payment_status', r.payment_status,
          'created_at', r.created_at,
          'paid_at', r.paid_at,
          'order_nsu', r.order_nsu,
          'expected_amount_cents', r.expected_amount_cents,
          'payment_provider', r.payment_provider,
          'checkout_url', r.checkout_url,
          'transaction_nsu', r.payment_transaction_nsu,
          'receipt_url', r.payment_receipt_url,
          'capture_method', r.capture_method,
          'expires_at', r.expires_at,
          'confirmation_whatsapp_sent_at', r.confirmation_whatsapp_sent_at
        )
        order by r.created_at desc
      )
      from public.reservations r
    ), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$$;

create or replace function public.admin_mark_confirmation_whatsapp_sent_session(
  p_session_token text,
  p_reservation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  r public.reservations%rowtype;
  v_sent_at timestamptz;
begin
  if not private.admin_session_ok(p_session_token) then
    raise exception 'Sessao administrativa invalida ou expirada.';
  end if;

  select *
  into r
  from public.reservations
  where id = p_reservation_id
  for update;

  if r.id is null then
    raise exception 'Pedido nao encontrado.';
  end if;

  if r.payment_status <> 'paid' then
    raise exception 'Confirme o pagamento antes de enviar a mensagem.';
  end if;

  if r.confirmation_whatsapp_sent_at is not null then
    return jsonb_build_object(
      'ok', false,
      'already_sent', true,
      'sent_at', r.confirmation_whatsapp_sent_at
    );
  end if;

  update public.reservations
  set confirmation_whatsapp_sent_at = now()
  where id = r.id
    and confirmation_whatsapp_sent_at is null
  returning confirmation_whatsapp_sent_at
  into v_sent_at;

  if v_sent_at is null then
    select confirmation_whatsapp_sent_at
    into v_sent_at
    from public.reservations
    where id = r.id;

    return jsonb_build_object(
      'ok', false,
      'already_sent', true,
      'sent_at', v_sent_at
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'already_sent', false,
    'sent_at', v_sent_at,
    'buyer_name', r.buyer_name,
    'whatsapp', r.whatsapp,
    'numbers', to_jsonb(r.numbers)
  );
end;
$$;

revoke all on function public.admin_mark_confirmation_whatsapp_sent_session(text, uuid) from public;
grant execute on function public.admin_mark_confirmation_whatsapp_sent_session(text, uuid) to anon, authenticated;

-- Mantem o dashboard acessivel somente pelas permissoes que a versao anterior ja usa.
revoke all on function public.admin_dashboard_session(text) from public;
grant execute on function public.admin_dashboard_session(text) to anon, authenticated;
