-- ============================================================
-- ADMIN: SENHA PARA CONFIRMAR ACOES
-- Senha configurada: 6253
-- ============================================================

create table if not exists private.raffle_admin_action_pin (
  id smallint primary key default 1 check (id = 1),
  pin_sha256 text not null,
  updated_at timestamptz not null default now()
);

alter table private.raffle_admin_action_pin enable row level security;
revoke all on private.raffle_admin_action_pin from public, anon, authenticated;

insert into private.raffle_admin_action_pin(id, pin_sha256, updated_at)
values (
  1,
  encode(extensions.digest('6253'::text, 'sha256'::text), 'hex'),
  now()
)
on conflict (id) do update
set pin_sha256 = excluded.pin_sha256,
    updated_at = now();

create or replace function public.admin_verify_action_pin_session(
  p_session_token text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_expected text;
  v_received text;
begin
  if not private.admin_session_ok(p_session_token) then
    raise exception 'Sessao administrativa invalida ou expirada.';
  end if;

  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false);
  end if;

  select pin_sha256
  into v_expected
  from private.raffle_admin_action_pin
  where id = 1;

  v_received := encode(
    extensions.digest(p_pin::text, 'sha256'::text),
    'hex'
  );

  return jsonb_build_object(
    'ok',
    v_expected is not null and v_received = v_expected
  );
end;
$$;

revoke all on function public.admin_verify_action_pin_session(text,text) from public;
grant execute on function public.admin_verify_action_pin_session(text,text) to anon, authenticated;

-- ============================================================
-- RIFA: DOACOES SEM NUMERO + PAGAMENTO EM DINHEIRO
-- Execute TODO este arquivo no SQL Editor do Supabase.
-- Esta atualizacao pressupoe a versao anterior do Admin/PWA instalada.
-- ============================================================

alter table public.reservations
  add column if not exists cash_received_by text;
alter table public.reservations
  add column if not exists cash_received_phone text;

create table if not exists private.raffle_donations (
  id uuid primary key default gen_random_uuid(),
  amount_cents integer not null check (amount_cents > 0),
  created_at timestamptz not null default now()
);
alter table private.raffle_donations enable row level security;
revoke all on private.raffle_donations from public, anon, authenticated;

create or replace function private.start_cash_payment_internal(
  p_name text,
  p_whatsapp text,
  p_numbers integer[],
  p_cash_received_by text,
  p_cash_received_phone text
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
  select * into v_state from public.raffle_public_state where id=1 for update;
  if v_state.sales_closed or now() >= v_state.draw_at then raise exception 'As vendas desta rifa estao encerradas.'; end if;
  if length(trim(coalesce(p_name,''))) < 2 or length(trim(coalesce(p_name,''))) > 80 then raise exception 'Digite um nome valido.'; end if;
  if coalesce(p_whatsapp,'') !~ '^[0-9]{10,15}$' then raise exception 'Digite um WhatsApp valido com DDD.'; end if;
  if length(trim(coalesce(p_cash_received_by,''))) < 2 or length(trim(coalesce(p_cash_received_by,''))) > 80 then raise exception 'Informe para quem o dinheiro foi entregue.'; end if;
  if coalesce(p_cash_received_phone,'') !~ '^[0-9]{10,15}$' then raise exception 'Digite o telefone de quem recebeu o dinheiro.'; end if;
  if coalesce(cardinality(p_numbers),0) < 1 then raise exception 'Escolha pelo menos um numero.'; end if;

  select array_agg(distinct x order by x) into v_numbers from unnest(p_numbers) x;
  if cardinality(v_numbers) <> cardinality(p_numbers) then raise exception 'Existem numeros repetidos na selecao.'; end if;
  if exists(select 1 from unnest(v_numbers) x where x<1 or x>200) then raise exception 'Selecao contem numero invalido.'; end if;

  perform n.number from public.raffle_numbers n where n.number=any(v_numbers) order by n.number for update;
  select count(*) into v_total from public.raffle_numbers n where n.number=any(v_numbers);
  if v_total <> cardinality(v_numbers) then raise exception 'Um ou mais numeros nao existem.'; end if;
  if exists(select 1 from public.raffle_numbers n where n.number=any(v_numbers) and n.status<>'available') then
    raise exception 'Um dos numeros escolhidos esta indisponivel. Atualize e escolha outro.';
  end if;

  v_order_nsu := 'DIN-' || replace(v_id::text,'-','');
  v_amount := cardinality(v_numbers) * 1000;
  insert into public.reservations(
    id,buyer_name,whatsapp,numbers,payment_status,order_nsu,expected_amount_cents,
    payment_provider,expires_at,cash_received_by,cash_received_phone
  ) values (
    v_id,trim(p_name),p_whatsapp,v_numbers,'pending',v_order_nsu,v_amount,
    'cash',null,trim(p_cash_received_by),p_cash_received_phone
  );
  update public.raffle_numbers set status='pending',updated_at=now() where number=any(v_numbers);

  return jsonb_build_object(
    'ok',true,'order_id',v_id,'order_nsu',v_order_nsu,'amount_cents',v_amount,
    'numbers',to_jsonb(v_numbers),'expires_at',null,
    'cash_received_by',trim(p_cash_received_by),'cash_received_phone',p_cash_received_phone
  );
end;
$$;

create or replace function public.start_cash_payment(
  p_name text,
  p_whatsapp text,
  p_numbers integer[],
  p_cash_received_by text,
  p_cash_received_phone text
)
returns jsonb
language sql
security definer
set search_path = pg_catalog, extensions
as $$
  select private.start_cash_payment_internal(p_name,p_whatsapp,p_numbers,p_cash_received_by,p_cash_received_phone);
$$;
revoke all on function private.start_cash_payment_internal(text,text,integer[],text,text) from public;
revoke all on function public.start_cash_payment(text,text,integer[],text,text) from public;
grant execute on function private.start_cash_payment_internal(text,text,integer[],text,text) to service_role;
grant execute on function public.start_cash_payment(text,text,integer[],text,text) to service_role;

create or replace function public.admin_add_donation_session(p_session_token text,p_amount_cents integer)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare v_id uuid; v_created timestamptz;
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  if coalesce(p_amount_cents,0) <= 0 or p_amount_cents > 100000000 then raise exception 'Valor de doacao invalido.'; end if;
  insert into private.raffle_donations(amount_cents) values(p_amount_cents)
  returning id,created_at into v_id,v_created;
  return jsonb_build_object('ok',true,'id',v_id,'amount_cents',p_amount_cents,'created_at',v_created);
end;
$$;

create or replace function public.admin_delete_donation_session(p_session_token text,p_donation_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare v_amount integer;
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  delete from private.raffle_donations where id=p_donation_id returning amount_cents into v_amount;
  if v_amount is null then raise exception 'Doacao nao encontrada.'; end if;
  return jsonb_build_object('ok',true,'amount_cents',v_amount);
end;
$$;

-- Dinheiro e Pix pessoal sao manuais: ao desfazer Pago, ficam Pendentes sem prazo.
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
      capture_method=case when payment_provider='personal_pix' then 'pix_pessoal' when payment_provider='cash' then 'dinheiro' else capture_method end
      where id=r.id;
  else
    update public.raffle_numbers set status='pending',updated_at=now() where number=any(r.numbers);
    update public.reservations set payment_status='pending',paid_at=null,
      expires_at=case when payment_provider in ('personal_pix','cash') then null else now()+interval '2 hours' end
      where id=r.id;
  end if;
  return jsonb_build_object('ok',true);
end;
$$;

create or replace function public.admin_dashboard_session(p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, extensions
as $$
declare
  v_result jsonb; v_winner_name text; v_winner_whatsapp text;
  v_state public.raffle_public_state%rowtype;
begin
  if not private.admin_session_ok(p_session_token) then raise exception 'Sessao administrativa invalida ou expirada.'; end if;
  perform private.release_expired_pending_internal();
  select * into v_state from public.raffle_public_state where id=1;
  if v_state.winner_reservation_id is not null then
    select r.buyer_name,r.whatsapp into v_winner_name,v_winner_whatsapp from public.reservations r where r.id=v_state.winner_reservation_id;
  end if;
  select jsonb_build_object(
    'stats',jsonb_build_object(
      'available',(select count(*) from public.raffle_numbers where status='available'),
      'pending',(select count(*) from public.raffle_numbers where status='pending'),
      'paid',(select count(*) from public.raffle_numbers where status='paid'),
      'buyers',(select count(*) from public.reservations where payment_status<>'expired'),
      'donation_total_cents',(select coalesce(sum(amount_cents),0) from private.raffle_donations)
    ),
    'state',jsonb_build_object(
      'sales_closed',v_state.sales_closed,'draw_at',v_state.draw_at,'instagram_handle',v_state.instagram_handle,
      'winner_number',v_state.winner_number,'winner_name',v_winner_name,'winner_whatsapp',v_winner_whatsapp,'drawn_at',v_state.drawn_at
    ),
    'numbers',coalesce((select jsonb_agg(jsonb_build_object('number',n.number,'status',n.status) order by n.number) from public.raffle_numbers n),'[]'::jsonb),
    'reservations',coalesce((select jsonb_agg(jsonb_build_object(
      'id',r.id,'buyer_name',r.buyer_name,'whatsapp',r.whatsapp,'numbers',to_jsonb(r.numbers),
      'payment_status',r.payment_status,'created_at',r.created_at,'paid_at',r.paid_at,'order_nsu',r.order_nsu,
      'expected_amount_cents',r.expected_amount_cents,'payment_provider',r.payment_provider,'checkout_url',r.checkout_url,
      'transaction_nsu',r.payment_transaction_nsu,'receipt_url',r.payment_receipt_url,'capture_method',r.capture_method,
      'expires_at',r.expires_at,'confirmation_whatsapp_sent_at',r.confirmation_whatsapp_sent_at,
      'cash_received_by',r.cash_received_by,'cash_received_phone',r.cash_received_phone
    ) order by r.created_at desc) from public.reservations r),'[]'::jsonb),
    'donations',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'amount_cents',d.amount_cents,'created_at',d.created_at) order by d.created_at desc) from private.raffle_donations d),'[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.admin_add_donation_session(text,integer) from public;
revoke all on function public.admin_delete_donation_session(text,uuid) from public;
revoke all on function public.admin_dashboard_session(text) from public;
grant execute on function public.admin_add_donation_session(text,integer) to anon, authenticated;
grant execute on function public.admin_delete_donation_session(text,uuid) to anon, authenticated;
grant execute on function public.admin_dashboard_session(text) to anon, authenticated;
