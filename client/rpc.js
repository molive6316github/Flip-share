// The entire client/server API. Everything the game does goes through these two functions.
const DB_URL = 'https://YOUR-DB-HOST/rest/v1';   // placeholders: set your own
const DB_KEY = 'YOUR-PUBLIC-ANON-KEY';           // a public key; the database rules are what protect you

async function rpc(fn, args) {
  const r = await fetch(DB_URL + '/rpc/flip_' + fn, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: DB_KEY },
    body: JSON.stringify(args || {}),
  });
  return r.json();
}

const SESS = { user: null, token: null };   // filled in after login/register
let STATE = null;                            // the last state the server sent us

// An authenticated action: attach who we are, then adopt whatever state the server returns.
async function act(fn, args) {
  let j;
  try { j = await rpc(fn, Object.assign({ p_user: SESS.user, p_token: SESS.token }, args)); }
  catch (e) { return { ok: false, error: 'network' }; }
  if (!j || j.ok === undefined) return { ok: false, error: 'Server error' };
  if (j.error === 'auth') { SESS.user = SESS.token = null; return j; }   // bad or expired session
  if (j.state) STATE = j.state;                                           // the server is the source of truth
  return j;
}

// usage:
//   await act('send', { p_to: 'someone', p_amount: 500 });
//   await act('pbot_save', { p_id: null, p_name: 'Helper', p_charter: '...', ... });
