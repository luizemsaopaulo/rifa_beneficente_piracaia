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
