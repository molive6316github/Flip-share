-- A bot a player hires. It talks, and it can pay grants out of the OWNER's wallet,
-- under rules the owner sets. Needs 01 and 02.
create table if not exists flip_bot (
  id serial primary key,
  owner text not null unique references flip_users (key),
  name text not null,
  charter text not null,                       -- plain words from the owner: what the bot should do
  grant_max bigint not null default 2000,      -- most per grant
  grant_day bigint not null default 20000,     -- most per 24 hours
  min_flips int not null default 0,            -- owner-set eligibility
  min_age_hours int not null default 0,
  days_between int not null default 1
);
create table if not exists flip_bot_log (id bigserial primary key, bot int not null, to_key text not null, amt bigint not null, at timestamptz not null default now());
create table if not exists flip_bot_ok (bot int not null, key text not null, at timestamptz not null default now(), primary key (bot, key));   -- one-off exceptions
alter table flip_bot enable row level security; alter table flip_bot_log enable row level security; alter table flip_bot_ok enable row level security;
alter table flip_players add column if not exists flips int not null default 0;

-- How much could this bot pay this player right now? (the AI is shown this number; the pay step re-checks it)
create or replace function flip_bot_room(a_bot int, a_key text) returns jsonb language plpgsql security definer as $$
declare b flip_bot; o flip_players; t flip_players; today bigint; ex boolean;
begin
  select * into b from flip_bot where id = a_bot;
  select * into o from flip_players where key = b.owner;
  select * into t from flip_players where key = a_key;
  if t.key is null then return jsonb_build_object('max', 0, 'why', 'no such player'); end if;
  if t.key = o.key then return jsonb_build_object('max', 0, 'why', 'a bot cannot pay its own owner'); end if;
  ex := exists (select 1 from flip_bot_ok where bot = b.id and key = t.key and at > now() - interval '3 days');   -- owner said "make an exception"
  if t.flips < b.min_flips and not ex then return jsonb_build_object('max', 0, 'why', 'they need ' || b.min_flips || '+ flips first'); end if;
  if not ex and not exists (select 1 from flip_users where key = t.key and created <= now() - make_interval(hours => b.min_age_hours)) then
    return jsonb_build_object('max', 0, 'why', 'the account is under ' || b.min_age_hours || ' hours old'); end if;
  if not ex and exists (select 1 from flip_bot_log where bot = b.id and to_key = t.key and at > now() - make_interval(days => b.days_between)) then
    return jsonb_build_object('max', 0, 'why', 'they already got a grant in the last ' || b.days_between || ' days'); end if;
  select coalesce(sum(amt), 0) into today from flip_bot_log where bot = b.id and at > now() - interval '24 hours';
  return jsonb_build_object('max', greatest(0, least(b.grant_max, b.grant_day - today, o.bank - 1000)), 'why', '');   -- the owner always keeps $1,000
end $$;

-- Pay a grant. Called by the worker with the AI's PROPOSED amount; the database decides whether it is allowed.
create or replace function flip_bot_grant(a_bot int, a_to text, a_amount bigint) returns jsonb language plpgsql security definer as $$
declare b flip_bot; t flip_players; room jsonb;
begin
  perform pg_advisory_xact_lock(7);
  select * into b from flip_bot where id = a_bot;
  select * into t from flip_players where lower(name) = lower(btrim(coalesce(a_to, ''))) limit 1;
  if b.id is null or t.key is null then return jsonb_build_object('ok', false, 'why', 'not found'); end if;
  room := flip_bot_room(b.id, t.key);
  if a_amount < 1000 then return jsonb_build_object('ok', false, 'why', 'a grant is at least $1,000'); end if;
  if (room ->> 'max')::bigint < a_amount then return jsonb_build_object('ok', false, 'why', coalesce(nullif(room ->> 'why', ''), 'over the most it may give now')); end if;
  update flip_players set bank = bank - a_amount where key = b.owner;
  update flip_players set bank = bank + a_amount where key = t.key;
  insert into flip_bot_log (bot, to_key, amt) values (b.id, t.key, a_amount);
  delete from flip_bot_ok where bot = b.id and key = t.key;       -- an exception is good for one grant
  return jsonb_build_object('ok', true, 'paid', a_amount);
end $$;
