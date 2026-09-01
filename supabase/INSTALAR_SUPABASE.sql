-- ============================================================
-- RIFA BENEFICENTE PIRACAIA - INSTALACAO SUPABASE
-- 200 numeros | Sorteio: 18/10/2026 20:00 (America/Sao_Paulo)
-- Instagram: @TUDODEHELENA
-- ============================================================
-- Pode executar este arquivo inteiro no SQL Editor do Supabase.
-- Ele NAO apaga reservas existentes se for executado novamente.
-- ============================================================

create extension if not exists pgcrypto;
create schema if not exists private;

revoke all on schema private from public;
grant usage on schema private to anon, authenticated;

create table if not exists public.raffle_numbers (
  number integer primary key check (number between 1 and 200),
  status text not null default 'available'
    check (status in ('available', 'reserved', 'paid')),
  updated_at timestamptz not null default now()
);

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  buyer_name text not null,
  whatsapp text not null,
  numbers integer[] not null,
  payment_status text not null default 'reserved'
    check (payment_status in ('reserved', 'paid')),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

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
select n, 'available'
from generate_series(1, 200) as n
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

-- ------------------------------------------------------------
-- RLS / PRIVILEGIOS
-- ------------------------------------------------------------

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
create policy "public read raffle numbers"
on public.raffle_numbers
for select
to anon, authenticated
using (true);

drop policy if exists "public read raffle state" on public.raffle_public_state;
create policy "public read raffle state"
on public.raffle_public_state
for select
to anon, authenticated
using (true);

-- Nenhuma policy publica e criada para reservations.
-- Assim nome e WhatsApp NAO ficam disponiveis para leitura publica.

-- ------------------------------------------------------------
-- FUNCOES INTERNAS (schema private, nao exposto pela Data API)
-- ------------------------------------------------------------

create or replace function private.admin_password_ok(p_password text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from private.raffle_admin_secret s
    where s.id = 1
      and s.password_sha256 = encode(digest(coalesce(p_password, ''), 'sha256'), 'hex')
  );
$$;

create or replace function private.reserve_numbers_internal(
  p_name text,
  p_whatsapp text,
  p_numbers integer[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_numbers integer[];
  v_id uuid;
  v_total integer;
  v_state public.raffle_public_state%rowtype;
begin
  select * into v_state
  from public.raffle_public_state
  where id = 1
  for update;

  if v_state.sales_closed or now() >= v_state.draw_at then
    raise exception 'As reservas desta rifa estao encerradas.';
  end if;

  if length(trim(coalesce(p_name, ''))) < 2 or length(trim(coalesce(p_name, ''))) > 80 then
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
  from unnest(p_numbers) as x;

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
    select 1 from public.raffle_numbers n
    where n.number = any(v_numbers)
      and n.status <> 'available'
  ) then
    raise exception 'Um dos numeros escolhidos acabou de ser reservado. Atualize e escolha outro.';
  end if;

  insert into public.reservations(buyer_name, whatsapp, numbers, payment_status)
  values (trim(p_name), p_whatsapp, v_numbers, 'reserved')
  returning id into v_id;

  update public.raffle_numbers
  set status = 'reserved',
      updated_at = now()
  where number = any(v_numbers);

  return jsonb_build_object(
    'ok', true,
    'reservation_id', v_id,
    'numbers', to_jsonb(v_numbers)
  );
end;
$$;

create or replace function private.admin_dashboard_internal(p_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
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
      'reserved', (select count(*) from public.raffle_numbers where status = 'reserved'),
      'paid', (select count(*) from public.raffle_numbers where status = 'paid'),
      'buyers', (select count(*) from public.reservations)
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
          'paid_at', r.paid_at
        )
        order by r.created_at desc
      )
      from public.reservations r
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

create or replace function private.admin_set_payment_internal(
  p_password text,
  p_reservation_id uuid,
  p_paid boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_numbers integer[];
begin
  if not private.admin_password_ok(p_password) then
    raise exception 'Senha incorreta.';
  end if;

  select r.numbers into v_numbers
  from public.reservations r
  where r.id = p_reservation_id
  for update;

  if v_numbers is null then
    raise exception 'Reserva nao encontrada.';
  end if;

  update public.reservations
  set payment_status = case when p_paid then 'paid' else 'reserved' end,
      paid_at = case when p_paid then now() else null end
  where id = p_reservation_id;

  update public.raffle_numbers
  set status = case when p_paid then 'paid' else 'reserved' end,
      updated_at = now()
  where number = any(v_numbers);

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function private.admin_cancel_reservation_internal(
  p_password text,
  p_reservation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_numbers integer[];
  v_winner_reservation uuid;
begin
  if not private.admin_password_ok(p_password) then
    raise exception 'Senha incorreta.';
  end if;

  select winner_reservation_id into v_winner_reservation
  from public.raffle_public_state
  where id = 1;

  if v_winner_reservation = p_reservation_id then
    raise exception 'A reserva vencedora nao pode ser cancelada.';
  end if;

  select r.numbers into v_numbers
  from public.reservations r
  where r.id = p_reservation_id
  for update;

  if v_numbers is null then
    raise exception 'Reserva nao encontrada.';
  end if;

  update public.raffle_numbers
  set status = 'available',
      updated_at = now()
  where number = any(v_numbers);

  delete from public.reservations
  where id = p_reservation_id;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function private.admin_set_sales_closed_internal(
  p_password text,
  p_closed boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.admin_password_ok(p_password) then
    raise exception 'Senha incorreta.';
  end if;

  if exists (select 1 from public.raffle_public_state where id = 1 and winner_number is not null)
     and p_closed = false then
    raise exception 'Nao e possivel reabrir as vendas depois do sorteio oficial.';
  end if;

  update public.raffle_public_state
  set sales_closed = p_closed
  where id = 1;

  return jsonb_build_object('ok', true, 'sales_closed', p_closed);
end;
$$;

create or replace function private.admin_draw_winner_internal(p_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state public.raffle_public_state%rowtype;
  v_paid_numbers integer[];
  v_number integer;
  v_reservation public.reservations%rowtype;
  v_index integer;
begin
  if not private.admin_password_ok(p_password) then
    raise exception 'Senha incorreta.';
  end if;

  select * into v_state
  from public.raffle_public_state
  where id = 1
  for update;

  if v_state.winner_number is not null then
    raise exception 'O sorteio oficial ja foi realizado.';
  end if;

  if now() < v_state.draw_at then
    raise exception 'O sorteio oficial so sera liberado em 18/10/2026 as 20h.';
  end if;

  select array_agg(number order by number)
  into v_paid_numbers
  from public.raffle_numbers
  where status = 'paid';

  if coalesce(cardinality(v_paid_numbers), 0) = 0 then
    raise exception 'Nao existem numeros pagos para sortear.';
  end if;

  -- Escolha aleatoria feita no servidor.
  v_index := 1 + floor(random() * cardinality(v_paid_numbers))::integer;
  v_number := v_paid_numbers[v_index];

  select *
  into v_reservation
  from public.reservations r
  where r.payment_status = 'paid'
    and v_number = any(r.numbers)
  order by r.created_at
  limit 1;

  if v_reservation.id is null then
    raise exception 'Nao foi possivel localizar o comprador do numero sorteado.';
  end if;

  update public.raffle_public_state
  set sales_closed = true,
      winner_number = v_number,
      winner_reservation_id = v_reservation.id,
      drawn_at = now()
  where id = 1;

  return jsonb_build_object(
    'number', v_number,
    'buyer_name', v_reservation.buyer_name,
    'whatsapp', v_reservation.whatsapp,
    'drawn_at', now()
  );
end;
$$;

-- ------------------------------------------------------------
-- WRAPPERS PUBLICOS PARA RPC
-- Nao usam SECURITY DEFINER; apenas chamam as funcoes internas.
-- ------------------------------------------------------------

create or replace function public.reserve_numbers(
  p_name text,
  p_whatsapp text,
  p_numbers integer[]
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.reserve_numbers_internal(p_name, p_whatsapp, p_numbers);
$$;

create or replace function public.admin_dashboard(p_password text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.admin_dashboard_internal(p_password);
$$;

create or replace function public.admin_set_payment(
  p_password text,
  p_reservation_id uuid,
  p_paid boolean
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.admin_set_payment_internal(p_password, p_reservation_id, p_paid);
$$;

create or replace function public.admin_cancel_reservation(
  p_password text,
  p_reservation_id uuid
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.admin_cancel_reservation_internal(p_password, p_reservation_id);
$$;

create or replace function public.admin_set_sales_closed(
  p_password text,
  p_closed boolean
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.admin_set_sales_closed_internal(p_password, p_closed);
$$;

create or replace function public.admin_draw_winner(p_password text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.admin_draw_winner_internal(p_password);
$$;

revoke all on function private.admin_password_ok(text) from public;
revoke all on function private.reserve_numbers_internal(text, text, integer[]) from public;
revoke all on function private.admin_dashboard_internal(text) from public;
revoke all on function private.admin_set_payment_internal(text, uuid, boolean) from public;
revoke all on function private.admin_cancel_reservation_internal(text, uuid) from public;
revoke all on function private.admin_set_sales_closed_internal(text, boolean) from public;
revoke all on function private.admin_draw_winner_internal(text) from public;

grant execute on function private.reserve_numbers_internal(text, text, integer[]) to anon, authenticated;
grant execute on function private.admin_dashboard_internal(text) to anon, authenticated;
grant execute on function private.admin_set_payment_internal(text, uuid, boolean) to anon, authenticated;
grant execute on function private.admin_cancel_reservation_internal(text, uuid) to anon, authenticated;
grant execute on function private.admin_set_sales_closed_internal(text, boolean) to anon, authenticated;
grant execute on function private.admin_draw_winner_internal(text) to anon, authenticated;

revoke all on function public.reserve_numbers(text, text, integer[]) from public;
revoke all on function public.admin_dashboard(text) from public;
revoke all on function public.admin_set_payment(text, uuid, boolean) from public;
revoke all on function public.admin_cancel_reservation(text, uuid) from public;
revoke all on function public.admin_set_sales_closed(text, boolean) from public;
revoke all on function public.admin_draw_winner(text) from public;

grant execute on function public.reserve_numbers(text, text, integer[]) to anon, authenticated;
grant execute on function public.admin_dashboard(text) to anon, authenticated;
grant execute on function public.admin_set_payment(text, uuid, boolean) to anon, authenticated;
grant execute on function public.admin_cancel_reservation(text, uuid) to anon, authenticated;
grant execute on function public.admin_set_sales_closed(text, boolean) to anon, authenticated;
grant execute on function public.admin_draw_winner(text) to anon, authenticated;

-- ------------------------------------------------------------
-- REALTIME
-- ------------------------------------------------------------

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'raffle_numbers'
  ) then
    alter publication supabase_realtime add table public.raffle_numbers;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'raffle_public_state'
  ) then
    alter publication supabase_realtime add table public.raffle_public_state;
  end if;
end $$;

-- FIM
