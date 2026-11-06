# skein-messagebox

The hosted BRC-33 messagebox for a [skein](https://github.com/shruggr/skein):
one skein keeps a mailbox for every key it hosts — one mailbox per key, boxes
inside it. In a host skein the hosted keys are the registered handles
(skein-onboard records each in `onboard/index`), and a handle's messagebox URL
is the skein's own URL plus `/messagebox`
(`https://accounts.testnet.1sat.app/messagebox`). Version **0.1.0**.

Mail addressed to the skein itself is not this app's: it arrives at the skein's
own `/sendMessage` (the stock `mail` program).

## What it is

One program, `bin/messagebox.wasm`, on three routes installed under
`/messagebox/` (skein `docs/APPS.md` §2). Every request is signed on a BRC-104
session: the kernel's `kernel.brc104` filter checks the session and the
signature, and the session's key is the **principal**. A standard client
shakes hands at the top of the domain (BRC-104; the SDK's AuthFetch) — the
same skein, the same key — and posts under the messagebox URL.

| route | filters | handler | what happens |
|---|---|---|---|
| `POST /messagebox/sendMessage` | `kernel.brc104`, `hosted` | `send` | the message stored and added to `{recipient, box}`'s list in the request's own step |
| `POST /messagebox/acknowledgeMessage` | `kernel.brc104` | `acknowledge` | the ids removed from the caller's own lists, in the request's own step |
| `POST /messagebox/listMessages` | `kernel.brc104`, `list` | (none: a read route) | the caller's box, answered by the filter; nothing is logged |

- **`hosted`** (a filter, before `send`): the recipient must be a key in the
  configured index, and not this skein's own; else the request is answered 403
  `ERR_ACCOUNT_REQUIRED`. A body `send` would refuse is answered here with the
  same refusal. A refused send writes no entry.
- **`list`** (a filter): the principal's box, as `{answer: …}`. No principal:
  401.
- `send` trusts its route's `hosted` filter: a root who routes to `send`
  without that filter hosts everyone.

The answers are BRC-33's (JSON) or BRC-231's (dag-cbor, an
`application/cbor` request), and the mail record is the shape skein's stock
messagebox kept: `{kind: "mail", op: "put", sender, recipient, box, body:
<cid>, json?, session}` — or, for a BRC-231 message carrying a `nonce`
(another instance's emit), `{…, subject?, nonce}` with no session. A message's
id is its record's CID.

### Configuration

`config.messagebox` in the installed manifest:

| key | meaning |
|---|---|
| `index` | the head whose record's `keys` map (`{<key, hex>: …}`) lists the hosted keys (default `onboard/index`) |

### State

The head `messagebox/mailbox` names `{kind: "mailbox", lists: [{recipient,
box, list: <cid>}]}` (sorted by recipient, then box), each list `{kind:
"mail-list", recipient, box, acked: <count>, messages: [{id: <mail cid>,
at}]}` — the messages not yet acknowledged, in arrival order.

## Build

Zig 0.16.0 (`mise.toml`), over skein-sdk.

```
zig build test   the body's checks, the lists, the answers — natively
zig build bin    bin/messagebox.wasm (committed; reproducible)
```

## Install

In a skein whose genesis no longer carries the stock messagebox routes under
`/messagebox/` (skein ≥ 0.3.0); the host image installs it beside onboard
(`images/host/etc/apps.json`).
