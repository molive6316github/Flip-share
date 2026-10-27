-- A rule-heavy action, start to finish. Needs 01_auth.sql.
create table if not exists flip_players (key text primary key references flip_users (key), name text not null, bank bigint not null default 100, best_peak bigint not null default 100);
create table if not exists flip_transfers (id bigserial primary key, from_key text not null, to_key text not null, amount bigint not null, tax bigint not null default 0, at timestamptz not null default now());
create table if not exists flip_events (id bigserial primary key, key text not null, msg text not null, seen boolean not null default false, at timestamptz not null default now());
alter table flip_players enable row level security; alter table flip_transfers enable row level security; alter table flip_events enable row level security;

create or replace function flip_err(m text) returns jsonb language sql as $$ select jsonb_build_object('ok', false, 'error', m) $$;

create or replace function flip_send(p_user text, p_token text, p_to text, p_amount bigint) returns jsonb language plpgsql security definer as $$
declare k text := flip_auth(p_user, p_token); p flip_players; r flip_players; tax bigint; got bigint; sent24 bigint;
begin
  if k is null then return flip_err('auth'); end if;
  -- one global lock for money moves: transfers run one at a time, so no double-spend races
  perform pg_advisory_xact_lock(7);
  select * into p from flip_players where key = k for update;
  select * into r from flip_players where key = lower(coalesce(p_to, '')) for update;
  if r.key is null or r.key = p.key then return flip_err('Pick another player'); end if;
  if p_amount is null or p_amount < 10 then return flip_err('Minimum transfer is $10'); end if;
  if p_amount > p.bank - 1 then return flip_err('You need to keep at least $1'); end if;
  -- daily limit scales with how rich you have ever been
  select coalesce(sum(amount), 0) into sent24 from flip_transfers where from_key = p.key and at > now() - interval '24 hours';
  if sent24 + p_amount > greatest(25000, floor(p.best_peak * .25)) then return flip_err('Daily send limit reached'); end if;
  tax := floor(p_amount * .10)::bigint; got := p_amount - tax;           -- 10% tax
  update flip_players set bank = bank - p_amount where key = p.key;
  update flip_players set bank = bank + got, best_peak = greatest(best_peak, bank + got) where key = r.key;
  insert into flip_transfers (from_key, to_key, amount, tax) values (p.key, r.key, p_amount, tax);
  insert into flip_events (key, msg) values (r.key, p.name || ' sent you $' || got || ' (after tax)');
  return jsonb_build_object('ok', true, 'received', got, 'tax', tax, 'state', (select to_jsonb(x) from flip_players x where key = p.key));
end $$;
