-- Accounts. The browser never sees these tables (RLS on, no policies).
create table if not exists flip_users (
  key text primary key,            -- lowercased username
  name text not null,              -- display name
  salt text not null,
  hash text not null,              -- hash of salt + password
  token_hash text not null default '',   -- hash of the current session token
  banned boolean not null default false,
  created timestamptz not null default now()
);
alter table flip_users enable row level security;

create or replace function flip_hash(p_pass text, p_salt text) returns text language sql immutable as $$
  select encode(sha256(convert_to(p_salt || ':' || p_pass, 'UTF8')), 'hex')
$$;
-- (a production setup should use a slow password hash such as bcrypt/argon2 via pgcrypto; this is the short version)

-- The token handed to the browser is random; only its hash is stored.
create or replace function flip_new_token(p_key text) returns text language plpgsql as $$
declare t text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  update flip_users set token_hash = encode(sha256(convert_to(t, 'UTF8')), 'hex') where key = p_key;
  return t;
end $$;

-- Who is this? Returns the account key, or null. Every other function starts with this.
create or replace function flip_auth(p_user text, p_token text) returns text language sql stable as $$
  select key from flip_users
  where key = lower(coalesce(p_user, '')) and not banned and token_hash <> ''
    and token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex')
$$;

create or replace function flip_register(p_user text, p_pass text) returns jsonb language plpgsql security definer as $$
declare k text; s text := gen_random_uuid()::text;
begin
  p_user := coalesce(p_user, ''); p_pass := coalesce(p_pass, '');
  if p_user !~ '^[A-Za-z0-9_.-]{3,14}$' then return jsonb_build_object('ok', false, 'error', 'Username: 3-14 letters, numbers, _ - .'); end if;
  if length(p_pass) < 6 or length(p_pass) > 64 then return jsonb_build_object('ok', false, 'error', 'Password: 6-64 characters'); end if;
  k := lower(p_user);
  begin
    insert into flip_users (key, name, salt, hash) values (k, p_user, s, flip_hash(p_pass, s));
  exception when unique_violation then return jsonb_build_object('ok', false, 'error', 'Username taken');
  end;
  return jsonb_build_object('ok', true, 'user', p_user, 'token', flip_new_token(k));
end $$;
