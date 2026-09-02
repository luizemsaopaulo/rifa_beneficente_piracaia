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
