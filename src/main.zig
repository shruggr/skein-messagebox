//! messagebox: the hosted BRC-33 messagebox, a skein app. One skein keeps the
//! mailboxes of every key it hosts — a mailbox per key, boxes inside it — on
//! skein's request pattern (shruggr/skein docs/VM.md "The door", "Requests";
//! docs/APPS.md §2): a request passes its route's filters before anything is
//! recorded; what passes is the entry, and the front door calls the route's
//! handler in-VM as the request's step; a read route's filter answers and
//! nothing is logged.
//!
//! Routes (installed under /messagebox/; every request signed on a BRC-104
//! session — kernel.brc104, the session's key the principal):
//!
//!   POST /messagebox/sendMessage         kernel.brc104, hosted → send
//!   POST /messagebox/acknowledgeMessage  kernel.brc104 → acknowledge
//!   POST /messagebox/listMessages        kernel.brc104, list   (a read route: no handler)
//!
//! Called (the front door's in-VM call, a handler gets {caller, body,
//! contentType, session, …}; a filter, the kernel's call, gets the same
//! fields and answers {pass} | {answer}):
//!   send          (handler) a message for a hosted key: the `mail` record
//!                 {kind: "mail", op: "put", sender (the session's identity),
//!                 recipient, box, body: <cid>, json?, session: {payload,
//!                 signature, nonce, yourNonce}} — or, for a BRC-231 message
//!                 that carries `nonce` (and `subject?`), another instance's
//!                 emit delivered on its own session, kept as the record it
//!                 emitted ({…, subject?, nonce}, no session) — stored with its
//!                 body and added to {recipient, box}'s list, in this step. A
//!                 message carrying a `signature` is refused (the session is the
//!                 proof).
//!   acknowledge   (handler) the ids removed from the lists whose recipient is
//!                 the caller, in this step; the records stay in the store
//!   list          (filter) the caller's box: {answer: …}, nothing logged
//!                 (CBOR: each with `message`, its mail record as kept)
//!   hosted        (filter, before send) the recipient is a key in the
//!                 configured index → pass; else an answer 403
//!                 ERR_ACCOUNT_REQUIRED (this skein's own key too: its own mail
//!                 arrives at its own /sendMessage); a body send would refuse is
//!                 answered here with send's refusal — nothing is logged for a
//!                 refused send
//!
//! Configuration: `config.messagebox.index` — the head whose record's `keys`
//! map (`{<key, hex>: <anything>}`) lists the keys hosted here (`onboard/index`
//! in a host skein: skein-onboard writes it at each registration).
//!
//! State: the head `messagebox/mailbox` names {kind: "mailbox", lists:
//! [{recipient, box, list: <cid>}]} (sorted), each {kind: "mail-list",
//! recipient, box, acked: <count>, messages: [{id: <mail cid>, at}]} — the
//! messages not yet acknowledged, in arrival order. The answers (JSON, or
//! BRC-231 dag-cbor for an application/cbor request) are the BRC-33 shapes
//! skein's stock messagebox answered.
const std = @import("std");
const cbor = @import("cbor");
const cid = cbor.cidm;
const sk = @import("sk");
const app = @import("app");
const dagjson = @import("dagjson");

const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const NAME = "messagebox";
/// The app's state: every hosted key's lists.
pub const MAILBOX = "messagebox/mailbox";
/// The index a host skein's registration app keeps (`config.messagebox.index`'s default in etc/app.json).
pub const DEFAULT_INDEX = "onboard/index";

pub fn main() u8 {
    return sk.main(NAME, run);
}

fn run(a: Allocator) !void {
    const in = try sk.input(a);
    if (!eql(u8, Value.str(in.get("kind")) orelse "", "call")) return sk.report("the messagebox app is called (its handlers and its filters)");
    const func = Value.str(in.get("fn")) orelse "";
    const arg = cbor.decode(a, Value.bytesOf(in.get("arg")) orelse "") catch return sk.report("the argument is not dag-cbor");
    if (eql(u8, func, "send")) return sk.answer(a, try (try send(a, in, arg)).value(a));
    if (eql(u8, func, "acknowledge")) return sk.answer(a, try (try acknowledge(a, arg)).value(a));
    // The filters: each answers, or (hosted) passes the request on.
    if (eql(u8, func, "list")) return sk.answer(a, try filterAnswer(a, try (try list(a, arg)).value(a)));
    if (eql(u8, func, "hosted")) return sk.answer(a, try hosted(a, in, arg));
    return sk.report("the messagebox app answers the fns send, acknowledge (its handlers) and list, hosted (its filters)");
}

// ---------------------------------------------------------------- configuration

/// `config.messagebox.index` of an app record: the head naming the hosted keys.
pub fn indexHead(manifest: Value) []const u8 {
    const all: Value = manifest.get("config") orelse .null;
    const c: Value = all.get(NAME) orelse .null;
    const h = Value.str(c.get("index")) orelse return DEFAULT_INDEX;
    return if (h.len == 0) DEFAULT_INDEX else h;
}

/// Whether `key` (33 bytes) is hosted by the index record (its `keys` map, by hex), and not this skein's own.
pub fn isHosted(a: Allocator, index: ?Value, key: []const u8, self: []const u8) !bool {
    if (eql(u8, key, self)) return false;
    const idx = index orelse return false;
    const keys: Value = idx.get("keys") orelse return false;
    if (keys != .map) return false;
    return keys.get(try sk.hex(a, key)) != null;
}

// ---------------------------------------------------------------- answers (JSON or BRC-231 dag-cbor, as asked)

pub const Resp = struct {
    status: u64,
    cbor: bool,
    body: Value,

    pub fn value(r: Resp, a: Allocator) !Value {
        var m = cbor.MapBuilder.init(a);
        try m.put("status", cbor.int(r.status));
        try m.put("type", cbor.string(if (r.cbor) "application/cbor" else "application/json"));
        try m.put("body", .{ .bytes = if (r.cbor) try cbor.encode(a, r.body) else try dagjson.encode(a, r.body) });
        return m.value();
    }
};

fn failure(a: Allocator, is_cbor: bool, status: u64, code: []const u8, description: []const u8) !Resp {
    var m = cbor.MapBuilder.init(a);
    try m.put("status", cbor.string("error"));
    try m.put("code", cbor.string(code));
    try m.put("description", cbor.string(description));
    return .{ .status = status, .cbor = is_cbor, .body = m.value() };
}

/// A read route's answer as its filter gives it (docs/APPS.md §2 "Filters"): `{answer: {status, type, body}}`.
pub fn filterAnswer(a: Allocator, response: Value) !Value {
    var m = cbor.MapBuilder.init(a);
    try m.put("answer", response);
    return m.value();
}

/// A filter's pass, the request as it is.
fn passOn(a: Allocator) !Value {
    var m = cbor.MapBuilder.init(a);
    try m.put("pass", .{ .map = &.{} });
    return m.value();
}

/// The request body: dag-cbor for application/cbor (BRC-231), else JSON (kept as JSON values: strings stay strings).
fn requestBody(a: Allocator, arg: Value) !struct { cbor: bool, v: ?Value } {
    const ct = Value.str(arg.get("contentType")) orelse "";
    const raw = Value.bytesOf(arg.get("body")) orelse "";
    if (std.ascii.eqlIgnoreCase(ct, "application/cbor")) return .{ .cbor = true, .v = cbor.decode(a, raw) catch null };
    if (raw.len == 0) return .{ .cbor = false, .v = .{ .map = &.{} } };
    const j = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return .{ .cbor = false, .v = null };
    return .{ .cbor = false, .v = try plainJson(a, j) };
}

/// JSON as values, no DAG-JSON reading (a request's own fields).
fn plainJson(a: Allocator, j: std.json.Value) !Value {
    return switch (j) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .string = s },
        .string => |s| .{ .string = s },
        .array => |arr| blk: {
            const out = try a.alloc(Value, arr.items.len);
            for (arr.items, 0..) |x, i| out[i] = try plainJson(a, x);
            break :blk .{ .array = out };
        },
        .object => |o| blk: {
            var l: std.ArrayList(cbor.Entry) = .empty;
            var it = o.iterator();
            while (it.next()) |e| try l.append(a, .{ .key = e.key_ptr.*, .value = try plainJson(a, e.value_ptr.*) });
            break :blk .{ .map = l.items };
        },
    };
}

fn keyOf(a: Allocator, v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    if (Value.bytesOf(x)) |b| return if (sk.isKey(b)) b else null;
    if (Value.str(x)) |s| {
        const b = sk.unhex(a, std.mem.trim(u8, s, " ")) orelse return null;
        return if (sk.isKey(b)) b else null;
    }
    if (x == .array and x.array.len == 1) return keyOf(a, x.array[0]);
    return null;
}

fn selfKey(in: Value) []const u8 {
    const s = in.get("self") orelse return "";
    return Value.bytesOf(s.get("identity")) orelse "";
}

/// The time of the request's step (an in-VM call from a step carries `step.at`), else the call's `now`.
fn atOf(in: Value) i128 {
    if (in.get("step")) |s| if (Value.intOf(s.get("at"))) |t| return t;
    return Value.intOf(in.get("now")) orelse 0;
}

// ---------------------------------------------------------------- a message, read from the request

/// A sendMessage request read: the mail record, its id and its body's block — or the refusal.
pub const Message = struct { cbor: bool, rec: Value, id: []const u8, body: cbor.Block, recipient: []const u8, box: []const u8 };

/// The request's message as send keeps it, or the answer refusing it (send's, and hosted's for the same request).
pub const Read = union(enum) { ok: Message, refused: Resp };

pub fn readMessage(a: Allocator, arg: Value) !Read {
    const rb = try requestBody(a, arg);
    const R = struct {
        fn no(al: Allocator, c: bool, status: u64, code: []const u8, d: []const u8) !Read {
            return .{ .refused = try failure(al, c, status, code, d) };
        }
    };
    const body = rb.v orelse return R.no(a, rb.cbor, 400, "ERR_BAD_BODY", "The body is not dag-cbor or JSON.");
    const m = body.get("message") orelse return R.no(a, rb.cbor, 400, "ERR_MESSAGE_REQUIRED", "Please provide a valid message to send!");
    const box = std.mem.trim(u8, Value.str(m.get("messageBox")) orelse "", " ");
    if (box.len == 0 or box[0] == ':') return R.no(a, rb.cbor, 400, "ERR_INVALID_MESSAGEBOX", "Invalid message box.");
    const recipient = keyOf(a, m.get("recipient")) orelse return R.no(a, rb.cbor, 400, "ERR_INVALID_RECIPIENT_KEY", "Invalid recipient key.");
    const sender = Value.bytesOf(arg.get("caller")) orelse return R.no(a, rb.cbor, 401, "ERR_AUTH_REQUIRED", "sendMessage needs an authenticated sender");

    // The body as dag-cbor: the bytes of a BRC-231 request (canonical), or a JSON body read as DAG-JSON.
    const mb = m.get("body") orelse return R.no(a, rb.cbor, 400, "ERR_INVALID_MESSAGE_BODY", "Invalid message body.");
    var json = false;
    const value: Value = if (rb.cbor) blk: {
        const b = Value.bytesOf(mb) orelse return R.no(a, true, 400, "ERR_INVALID_MESSAGE_BODY", "A BRC-231 body is dag-cbor bytes.");
        const v = cbor.decode(a, b) catch return R.no(a, true, 400, "ERR_INVALID_MESSAGE_BODY", "The body is not dag-cbor.");
        const blk2 = try cbor.block(a, v);
        if (!eql(u8, blk2.bytes, b)) return R.no(a, true, 400, "ERR_INVALID_MESSAGE_BODY", "The body is not canonical dag-cbor.");
        break :blk v;
    } else blk: {
        json = true;
        if (Value.str(mb)) |text| {
            if (text.len == 0) return R.no(a, false, 400, "ERR_INVALID_MESSAGE_BODY", "Invalid message body.");
            break :blk dagjson.decode(a, text) catch Value{ .string = text };
        }
        // A JSON value sent as it is: read as DAG-JSON through its text.
        break :blk dagjson.decode(a, try dagjson.encode(a, mb)) catch mb;
    };
    const blk = try cbor.block(a, value);

    var rec = cbor.MapBuilder.init(a);
    try rec.put("kind", cbor.string("mail"));
    try rec.put("op", cbor.string("put"));
    try rec.put("sender", .{ .bytes = sender });
    try rec.put("recipient", .{ .bytes = recipient });
    try rec.put("box", cbor.string(box));
    try rec.put("body", cbor.cidv(blk.cid));
    if (m.get("signature")) |x| if (x != .null) return R.no(a, rb.cbor, 400, "ERR_SIGNED_MESSAGE", "A message carries no signature: the session proves who sends it.");
    if (rb.cbor and Value.bytesOf(m.get("nonce")) != null) {
        // Another instance's emit, delivered on its own session — kept as the record it emitted
        // ({…, subject?, nonce}: the emit's own nonce, no session), so both sides know the message
        // by one CID. The session proves who sent it (`sender` is the caller).
        if (m.get("subject")) |s| if (s != .null) try rec.put("subject", cbor.cidv(Value.cidOf(s) orelse return R.no(a, true, 400, "ERR_INVALID_SUBJECT", "The subject is not a CID.")));
        try rec.put("nonce", m.get("nonce"));
    } else {
        if (json) try rec.put("json", .{ .bool = true });
        try rec.put("session", arg.get("session"));
    }
    const r = rec.value();
    return .{ .ok = .{ .cbor = rb.cbor, .rec = r, .id = try cbor.cidOfValue(a, r), .body = blk, .recipient = recipient, .box = box } };
}

/// send's answer for a kept message: BRC-33's (JSON) or BRC-231's (dag-cbor).
pub fn sentAnswer(a: Allocator, msg: Message, arg: Value) !Resp {
    const id_text = try cid.format(a, msg.id);
    var ok = cbor.MapBuilder.init(a);
    try ok.put("status", cbor.string("success"));
    if (msg.cbor) {
        try ok.put("messageId", cbor.string(id_text));
    } else {
        try ok.put("message", cbor.string("Your message has been sent to 1 recipient(s)."));
        // The stock client checks its own messageId comes back; `id` is the message's id here.
        const rb = try requestBody(a, arg);
        const m: Value = if (rb.v) |v| v.get("message") orelse .null else .null;
        var one = cbor.MapBuilder.init(a);
        try one.put("recipient", cbor.string(try sk.hex(a, msg.recipient)));
        try one.put("messageId", m.get("messageId") orelse cbor.string(id_text));
        const results = try a.alloc(Value, 1);
        results[0] = one.value();
        try ok.put("results", .{ .array = results });
    }
    try ok.put("id", cbor.string(id_text));
    return .{ .status = 200, .cbor = msg.cbor, .body = ok.value() };
}

// ---------------------------------------------------------------- hosted (a filter)

fn hosted(a: Allocator, in: Value, arg: Value) !Value {
    const msg = switch (try readMessage(a, arg)) {
        .ok => |m| m,
        .refused => |r| return filterAnswer(a, try r.value(a)),
    };
    const idx_head = indexHead(try app.manifestOf(a, NAME));
    const index: ?Value = if (try sk.head(a, idx_head)) |c| try sk.get(a, c) else null;
    if (!try isHosted(a, index, msg.recipient, selfKey(in)))
        return filterAnswer(a, try (try failure(a, msg.cbor, 403, "ERR_ACCOUNT_REQUIRED", "No mailbox for that recipient here.")).value(a));
    return passOn(a);
}

// ---------------------------------------------------------------- send (a handler: the request's step)

fn send(a: Allocator, in: Value, arg: Value) !Resp {
    const msg = switch (try readMessage(a, arg)) {
        .ok => |m| m,
        .refused => |r| return r,
    };
    // The record and its body stored, and the message added to its recipient's box — in this step.
    try sk.putBlock(msg.body.cid, msg.body.bytes);
    _ = try sk.put(a, msg.rec);
    const ls = try lists(a);
    if (try filed(a, ls, msg.recipient, msg.box, msg.id, atOf(in))) |next| try saveRoot(a, next);
    return sentAnswer(a, msg, arg);
}

// ---------------------------------------------------------------- the mailbox

pub const List = struct { recipient: []const u8, box: []const u8, cid: []const u8 };

fn lists(a: Allocator) ![]List {
    const root = (try sk.head(a, MAILBOX)) orelse return &.{};
    return listsOf(a, try sk.get(a, root));
}

pub fn listsOf(a: Allocator, r: Value) ![]List {
    var out: std.ArrayList(List) = .empty;
    if (r.get("lists")) |ls| if (ls == .array) for (ls.array) |x| try out.append(a, .{
        .recipient = Value.bytesOf(x.get("recipient")) orelse continue,
        .box = Value.str(x.get("box")) orelse continue,
        .cid = Value.cidOf(x.get("list")) orelse continue,
    });
    return out.items;
}

/// The lists with message `id` added to {recipient, box}'s (a new list record put), or null: it is there already.
fn filed(a: Allocator, ls_in: []const List, recipient: []const u8, box: []const u8, id: []const u8, at: i128) !?[]List {
    var ls = std.ArrayList(List).fromOwnedSlice(try a.dupe(List, ls_in));
    var idx: ?usize = null;
    for (ls.items, 0..) |l, i| if (eql(u8, l.recipient, recipient) and eql(u8, l.box, box)) {
        idx = i;
    };
    var messages: std.ArrayList(Value) = .empty;
    var acked: i128 = 0;
    if (idx) |i| {
        const l = try sk.get(a, ls.items[i].cid);
        acked = Value.intOf(l.get("acked")) orelse 0;
        if (l.get("messages")) |ms| if (ms == .array) for (ms.array) |x| {
            if (eql(u8, Value.cidOf(x.get("id")) orelse "", id)) return null; // already kept
            try messages.append(a, x);
        };
    }
    var m = cbor.MapBuilder.init(a);
    try m.put("id", cbor.cidv(id));
    try m.put("at", cbor.int(at));
    try messages.append(a, m.value());
    const c = try saveList(a, recipient, box, acked, messages.items);
    if (idx) |i| ls.items[i].cid = c else try ls.append(a, .{ .recipient = recipient, .box = box, .cid = c });
    return ls.items;
}

// ---------------------------------------------------------------- list (a filter: a read, nothing logged)

fn list(a: Allocator, arg: Value) !Resp {
    const rb = try requestBody(a, arg);
    const body = rb.v orelse return failure(a, rb.cbor, 400, "ERR_BAD_BODY", "The body is not dag-cbor or JSON.");
    const box = Value.str(body.get("messageBox")) orelse return failure(a, rb.cbor, 400, "ERR_MESSAGEBOX_REQUIRED", "Please provide the name of a valid MessageBox!");
    // A caller lists only what is addressed to its own key.
    const caller = Value.bytesOf(arg.get("caller")) orelse return failure(a, rb.cbor, 401, "ERR_AUTH_REQUIRED", "listMessages needs an authenticated caller");
    var out: std.ArrayList(Value) = .empty;
    for (try lists(a)) |l| {
        if (!eql(u8, l.recipient, caller) or !eql(u8, l.box, box)) continue;
        const ml = try sk.get(a, l.cid);
        const ms = ml.get("messages") orelse continue;
        if (ms != .array) continue;
        for (ms.array) |x| {
            const id = Value.cidOf(x.get("id")) orelse continue;
            const rec = try sk.get(a, id);
            const bc = Value.cidOf(rec.get("body")) orelse continue;
            const bytes = try sk.getBytes(a, bc);
            const sender = Value.bytesOf(rec.get("sender")) orelse continue;
            try out.append(a, try listed(a, rb.cbor, id, rec, bytes, sender, Value.intOf(x.get("at")) orelse 0));
        }
    }
    var r = cbor.MapBuilder.init(a);
    try r.put("status", cbor.string("success"));
    try r.put("messages", .{ .array = out.items });
    return .{ .status = 200, .cbor = rb.cbor, .body = r.value() };
}

/// One listed message, as BRC-33 (JSON) or BRC-231 (dag-cbor) has it.
pub fn listed(a: Allocator, is_cbor: bool, id: []const u8, rec: Value, bytes: []const u8, sender: []const u8, at: i128) !Value {
    var m = cbor.MapBuilder.init(a);
    try m.put("messageId", cbor.string(try cid.format(a, id)));
    if (is_cbor) {
        try m.put("body", .{ .bytes = bytes });
        try m.put("sender", .{ .bytes = sender });
        // The message itself, its record as kept (its id is that record's CID).
        try m.put("message", rec);
    } else {
        // {message: <the body as DAG-JSON>}, as text: the stock client unwraps `message`.
        var w = cbor.MapBuilder.init(a);
        try w.put("message", try cbor.decode(a, bytes));
        try m.put("body", cbor.string(try dagjson.encode(a, w.value())));
        try m.put("sender", cbor.string(try sk.hex(a, sender)));
        const t = try isoTime(a, at);
        try m.put("createdAt", cbor.string(t));
        try m.put("updatedAt", cbor.string(t));
    }
    return m.value();
}

// ---------------------------------------------------------------- acknowledge (a handler: the request's step)

fn acknowledge(a: Allocator, arg: Value) !Resp {
    const rb = try requestBody(a, arg);
    const body = rb.v orelse return failure(a, rb.cbor, 400, "ERR_BAD_BODY", "The body is not dag-cbor or JSON.");
    const caller = Value.bytesOf(arg.get("caller")) orelse return failure(a, rb.cbor, 401, "ERR_AUTH_REQUIRED", "acknowledgeMessage needs an authenticated caller");
    const ids = body.get("messageIds") orelse return failure(a, rb.cbor, 400, "ERR_INVALID_MESSAGE_ID", "Message IDs must be formatted as an array of strings!");
    if (ids != .array or ids.array.len == 0) return failure(a, rb.cbor, 400, "ERR_INVALID_MESSAGE_ID", "Message IDs must be formatted as an array of strings!");
    var wanted: std.ArrayList([]const u8) = .empty;
    for (ids.array) |x| {
        const s = Value.str(x) orelse return failure(a, rb.cbor, 400, "ERR_INVALID_MESSAGE_ID", "Message IDs must be formatted as an array of strings!");
        try wanted.append(a, cid.parse(a, s) catch continue);
    }
    // Only ids in the caller's own lists, not yet acknowledged: removed there, in this step.
    const ls = try a.dupe(List, try lists(a));
    var gone: usize = 0;
    for (ls) |*l| {
        if (!eql(u8, l.recipient, caller)) continue;
        const ml = try sk.get(a, l.cid);
        const r = try without(a, ml, wanted.items);
        if (r.removed == 0) continue;
        gone += r.removed;
        l.cid = try saveList(a, l.recipient, l.box, r.acked, r.kept);
    }
    if (gone == 0) return failure(a, rb.cbor, 400, "ERR_INVALID_ACKNOWLEDGMENT", "Message not found!");
    try saveRoot(a, ls);
    var ok = cbor.MapBuilder.init(a);
    try ok.put("status", cbor.string("success"));
    return .{ .status = 200, .cbor = rb.cbor, .body = ok.value() };
}

/// A list record with the messages `ids` names taken out: what stays, the new acknowledged count, how many went.
pub fn without(a: Allocator, ml: Value, ids: []const []const u8) !struct { kept: []const Value, acked: i128, removed: usize } {
    var acked = Value.intOf(ml.get("acked")) orelse 0;
    var kept: std.ArrayList(Value) = .empty;
    var removed: usize = 0;
    if (ml.get("messages")) |ms| if (ms == .array) for (ms.array) |x| {
        const id = Value.cidOf(x.get("id")) orelse "";
        var hit = false;
        for (ids) |i| if (eql(u8, i, id)) {
            hit = true;
        };
        if (hit) {
            acked += 1;
            removed += 1;
        } else try kept.append(a, x);
    };
    return .{ .kept = kept.items, .acked = acked, .removed = removed };
}

fn isoTime(a: Allocator, ms: i128) ![]const u8 {
    const secs: u64 = @intCast(@max(0, @divFloor(ms, 1000)));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), @as(u64, @intCast(@mod(ms, 1000))) });
}

fn saveList(a: Allocator, recipient: []const u8, box: []const u8, acked: i128, messages: []const Value) ![]const u8 {
    return sk.put(a, try listRecord(a, recipient, box, acked, messages));
}

pub fn listRecord(a: Allocator, recipient: []const u8, box: []const u8, acked: i128, messages: []const Value) !Value {
    var l = cbor.MapBuilder.init(a);
    try l.put("kind", cbor.string("mail-list"));
    try l.put("recipient", .{ .bytes = recipient });
    try l.put("box", cbor.string(box));
    try l.put("acked", cbor.int(acked));
    try l.put("messages", .{ .array = messages });
    return l.value();
}

fn saveRoot(a: Allocator, ls: []List) !void {
    try sk.advance(MAILBOX, try sk.put(a, try rootRecord(a, ls)));
}

/// The state record: the lists sorted by (recipient, box).
pub fn rootRecord(a: Allocator, ls: []List) !Value {
    std.mem.sort(List, ls, {}, struct {
        fn lt(_: void, x: List, y: List) bool {
            return switch (std.mem.order(u8, x.recipient, y.recipient)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.order(u8, x.box, y.box) == .lt,
            };
        }
    }.lt);
    const arr = try a.alloc(Value, ls.len);
    for (ls, 0..) |l, i| {
        var e = cbor.MapBuilder.init(a);
        try e.put("recipient", .{ .bytes = l.recipient });
        try e.put("box", cbor.string(l.box));
        try e.put("list", cbor.cidv(l.cid));
        arr[i] = e.value();
    }
    var r = cbor.MapBuilder.init(a);
    try r.put("kind", cbor.string("mailbox"));
    try r.put("lists", .{ .array = arr });
    return r.value();
}

// ---------------------------------------------------------------- tests

const alice_hex = "034f355bdcb7cc0af728ef3cceb9615d90684bb5b2ca5f859ab0f0b704075871aa";
const bob_hex = "02f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9";
const self_hex = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";

fn testArg(a: Allocator, ct: []const u8, body: []const u8, caller: ?[]const u8) !Value {
    var m = cbor.MapBuilder.init(a);
    try m.put("contentType", cbor.string(ct));
    try m.put("body", .{ .bytes = body });
    if (caller) |c| try m.put("caller", .{ .bytes = c });
    return m.value();
}

fn testIndex(a: Allocator, hexes: []const []const u8) !Value {
    var ks = cbor.MapBuilder.init(a);
    for (hexes) |h| try ks.put(h, cbor.string("someone"));
    var m = cbor.MapBuilder.init(a);
    try m.put("kind", cbor.string("onboard-index"));
    try m.put("keys", ks.value());
    return m.value();
}

test "hosted: a key in the index passes; any other key, and this skein's own, does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const alice = sk.unhex(a, alice_hex).?;
    const bob = sk.unhex(a, bob_hex).?;
    const self = sk.unhex(a, self_hex).?;
    const idx = try testIndex(a, &.{ alice_hex, self_hex });
    try std.testing.expect(try isHosted(a, idx, alice, self));
    try std.testing.expect(!try isHosted(a, idx, bob, self));
    try std.testing.expect(!try isHosted(a, idx, self, self));
    try std.testing.expect(!try isHosted(a, null, alice, self));
    try std.testing.expectEqualStrings("onboard/index", indexHead(try dagjson.decode(a, "{\"kind\":\"app\"}")));
    try std.testing.expectEqualStrings("x/keys", indexHead(try dagjson.decode(a, "{\"config\":{\"messagebox\":{\"index\":\"x/keys\"}}}")));
}

test "send: a JSON message read as the stock messagebox kept it; its answer has no admit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bob = sk.unhex(a, bob_hex).?;
    const body = "{\"message\":{\"recipient\":\"" ++ alice_hex ++ "\",\"messageBox\":\"inbox\",\"body\":\"{\\\"text\\\":\\\"hi\\\"}\",\"messageId\":\"m1\"}}";
    const arg = try testArg(a, "application/json", body, bob);
    const msg = (try readMessage(a, arg)).ok;
    try std.testing.expectEqualStrings("inbox", msg.box);
    try std.testing.expectEqualSlices(u8, sk.unhex(a, alice_hex).?, msg.recipient);
    try std.testing.expectEqualStrings("mail", Value.str(msg.rec.get("kind")).?);
    try std.testing.expectEqualSlices(u8, bob, Value.bytesOf(msg.rec.get("sender")).?);
    try std.testing.expect(msg.rec.get("json").?.bool);
    try std.testing.expectEqualSlices(u8, msg.id, try cbor.cidOfValue(a, msg.rec));
    const r = try (try sentAnswer(a, msg, arg)).value(a);
    try std.testing.expect(r.get("admit") == null);
    try std.testing.expectEqual(@as(i128, 200), Value.intOf(r.get("status")).?);
    const j = Value.bytesOf(r.get("body")).?;
    try std.testing.expect(std.mem.indexOf(u8, j, "\"messageId\":\"m1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "Your message has been sent to 1 recipient(s).") != null);
}

test "send: refusals — a signed message, a missing sender, a bad box" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bob = sk.unhex(a, bob_hex).?;
    const signed = "{\"message\":{\"recipient\":\"" ++ alice_hex ++ "\",\"messageBox\":\"inbox\",\"body\":\"x\",\"signature\":\"00\"}}";
    try std.testing.expectEqual(@as(u64, 400), (try readMessage(a, try testArg(a, "application/json", signed, bob))).refused.status);
    const ok = "{\"message\":{\"recipient\":\"" ++ alice_hex ++ "\",\"messageBox\":\"inbox\",\"body\":\"x\"}}";
    try std.testing.expectEqual(@as(u64, 401), (try readMessage(a, try testArg(a, "application/json", ok, null))).refused.status);
    const colon = "{\"message\":{\"recipient\":\"" ++ alice_hex ++ "\",\"messageBox\":\":ack\",\"body\":\"x\"}}";
    try std.testing.expectEqual(@as(u64, 400), (try readMessage(a, try testArg(a, "application/json", colon, bob))).refused.status);
}

test "send: a BRC-231 message with a nonce is kept as the record it emitted (no session)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mm = cbor.MapBuilder.init(a);
    try mm.put("recipient", .{ .bytes = sk.unhex(a, alice_hex).? });
    try mm.put("messageBox", cbor.string("chat"));
    try mm.put("body", .{ .bytes = try cbor.encode(a, cbor.string("hello")) });
    try mm.put("nonce", .{ .bytes = &[_]u8{ 1, 2, 3 } });
    var b = cbor.MapBuilder.init(a);
    try b.put("message", mm.value());
    const arg = try testArg(a, "application/cbor", try cbor.encode(a, b.value()), sk.unhex(a, bob_hex).?);
    const msg = (try readMessage(a, arg)).ok;
    try std.testing.expect(msg.rec.get("session") == null);
    try std.testing.expect(msg.rec.get("nonce") != null);
    const r = try (try sentAnswer(a, msg, arg)).value(a);
    try std.testing.expectEqualStrings("application/cbor", Value.str(r.get("type")).?);
}

test "acknowledge: only the listed ids go, counted as acknowledged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try cbor.cidOfValue(a, cbor.string("one"));
    const two = try cbor.cidOfValue(a, cbor.string("two"));
    var ms: [2]Value = undefined;
    for ([_][]const u8{ one, two }, 0..) |c, i| {
        var m = cbor.MapBuilder.init(a);
        try m.put("id", cbor.cidv(c));
        try m.put("at", cbor.int(1));
        ms[i] = m.value();
    }
    const l = try listRecord(a, sk.unhex(a, alice_hex).?, "inbox", 3, &ms);
    const r = try without(a, l, &.{two});
    try std.testing.expectEqual(@as(usize, 1), r.removed);
    try std.testing.expectEqual(@as(i128, 4), r.acked);
    try std.testing.expectEqual(@as(usize, 1), r.kept.len);
    try std.testing.expectEqualSlices(u8, one, Value.cidOf(r.kept[0].get("id")).?);
    try std.testing.expectEqual(@as(usize, 0), (try without(a, l, &.{})).removed);
}

test "the state record: lists sorted by recipient, then box; a list answer per format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try cbor.cidOfValue(a, cbor.string("x"));
    var ls = [_]List{
        .{ .recipient = sk.unhex(a, bob_hex).?, .box = "b", .cid = c },
        .{ .recipient = sk.unhex(a, alice_hex).?, .box = "z", .cid = c },
        .{ .recipient = sk.unhex(a, alice_hex).?, .box = "a", .cid = c },
    };
    const r = try rootRecord(a, &ls);
    const back = try listsOf(a, r);
    try std.testing.expectEqual(@as(usize, 3), back.len);
    // By the key's bytes: bob's (02…) before alice's (03…), then alice's boxes in order.
    try std.testing.expectEqualStrings("b", back[0].box);
    try std.testing.expectEqualStrings("a", back[1].box);
    try std.testing.expectEqualStrings("z", back[2].box);
    const bytes = try cbor.encode(a, cbor.string("hi"));
    const j = try listed(a, false, c, .null, bytes, sk.unhex(a, bob_hex).?, 1_790_000_000_250);
    try std.testing.expectEqualStrings("{\"message\":\"hi\"}", Value.str(j.get("body")).?);
    try std.testing.expectEqualStrings("2026-09-21T14:13:20.250Z", Value.str(j.get("createdAt")).?);
    const cb = try listed(a, true, c, .null, bytes, sk.unhex(a, bob_hex).?, 0);
    try std.testing.expectEqualSlices(u8, bytes, Value.bytesOf(cb.get("body")).?);
}

test "list: no caller is 401; a filter's answer wraps the response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try (try failure(a, false, 401, "ERR_AUTH_REQUIRED", "listMessages needs an authenticated caller")).value(a);
    const f = try filterAnswer(a, r);
    try std.testing.expectEqual(@as(i128, 401), Value.intOf(f.get("answer").?.get("status")).?);
}
