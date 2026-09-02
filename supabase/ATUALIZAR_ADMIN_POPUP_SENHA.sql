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
