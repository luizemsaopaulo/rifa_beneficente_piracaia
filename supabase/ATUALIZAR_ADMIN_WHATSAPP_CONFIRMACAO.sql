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
