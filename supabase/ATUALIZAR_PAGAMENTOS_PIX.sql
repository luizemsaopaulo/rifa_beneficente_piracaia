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
