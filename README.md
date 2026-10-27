# Flip-share

A small, sanitized walkthrough of how **Flip** (an MMO browser game) is built. These are teaching excerpts, simplified from the real code. The anti-cheat, admin tools, keys and the full game are not here.

## The shape of it

```
 browser (one static HTML file)
    │  fetch  POST /rpc/flip_<name>   { p_user, p_token, ...args }
    ▼
 Postgres (REST layer over SQL functions)
    │  every game action is one SECURITY DEFINER function
    ▼
 tables (RLS on, no direct access from the browser)

 a scheduled worker (a small serverless function)
    └─ picks work from the DB, asks an AI model what to say, sends it back through SQL functions
```

There is no app server. The browser can only call functions, and each function checks who you are, checks the rules, changes the tables and returns the new state. The client never decides outcomes. It draws what the server returns.

## What is in here

| File | What it shows |
|---|---|
| `client/rpc.js` | The whole client side of the API: `rpc()` and `act()` |
| `sql/01_auth.sql` | Accounts: hashed password, hashed session token, `auth()` |
| `sql/02_send_money.sql` | A rule-heavy action: row locks, a tax, a daily limit, an event log |
| `sql/03_personal_bot.sql` | A player-hired AI bot that pays grants from its owner's wallet under the owner's rules |
| `worker/bot_reply.js` | How the worker lets an AI model *propose* actions that SQL *validates* |

## Ideas worth stealing

1. **Make the database the only authority.** Tables have RLS on and no policies, so the browser can't read or write them. Only functions can.
2. **Return the new state from every action.** The client just adopts it, so it can't drift from the server.
3. **Hash the token you store.** A leaked table doesn't leak sessions.
4. **Take one advisory lock for money moves.** `pg_advisory_xact_lock` makes transfers serial, which kills whole classes of race/double-spend bugs.
5. **Let the AI propose, never decide.** The model returns JSON like `{"type":"grant","amount":2000}`. The SQL function re-checks every limit. A jailbroken prompt can only ask for something the rules already allow.
6. **Put the owner's rules in columns.** `min_flips`, `min_age_hours`, `days_between` are data the owner edits, not constants in code.

## Running the SQL

Each file is standalone enough to try in a scratch Postgres (it creates its own tiny tables):

```
psql -f sql/01_auth.sql -f sql/02_send_money.sql -f sql/03_personal_bot.sql
```
