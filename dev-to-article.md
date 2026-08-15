---
title: Zenoh's put is fire-and-forget, get isn't — a read-after-write race in Elixir
published: false
description: put/4 in Zenohex returns as soon as the write is queued locally, not once the remote storage has applied it. Here's how I found the race, confirmed it against zenoh's own tracking issue, and fixed it with a small Elixir wrapper.
tags: elixir, zenoh, zenohex, storage
---
This English version is an AI translation of [my original article on Qiita (in Japanese)](https://qiita.com/kikuyuta/items/578bceafe60b4bb53d31).

## Background

I've been experimenting with [Zenoh](https://zenoh.io) via its Elixir bindings, [Zenohex](https://hex.pm/packages/zenohex), not for its usual pub/sub use case but for its `put`/`get` storage feature. It mostly worked, except every so often the state I picked back up was one step behind. Digging into why turned into a fun rabbit hole, so here's the writeup.

## Reproducing it

To keep things simple, strip out the GenServer part entirely and just loop `put` immediately followed by `get` on the same key:

```elixir
{:ok, session_id} = Zenohex.Session.open(config)

Enum.each(1..2000, fn i ->
  payload = Integer.to_string(i)
  :ok = Zenohex.Session.put(session_id, key, payload)

  {:ok, replies} = Zenohex.Session.get(session_id, key, 3_000, consolidation: :latest)

  case Enum.find(replies, &match?(%Zenohex.Sample{}, &1)) do
    %Zenohex.Sample{payload: ^payload} -> :ok
    %Zenohex.Sample{payload: other} -> IO.puts("stale! put #{payload} but got #{other}")
    nil -> IO.puts("no reply at all")
  end
end)
```

Out of 2000 iterations, a small fraction print `stale!` — about 78 (3.9%) in one run. The interesting part: querying again immediately afterward almost always returns the correct value (the fastest I measured was a single extra `get` about 1ms later). So it's not that the value disappears — there's just a small window of lag before the write is actually visible.

## Why

`Zenohex.Session.put/4` is a thin Rustler wrapper around zenoh-rust's `put`. Looking at the [NIF implementation](https://github.com/biyooon-ex/zenohex/blob/main/native/zenohex_nif/src/session.rs):

```rust
fn session_put(...) -> rustler::NifResult<rustler::Atom> {
    ...
    publication_builder
        .apply_opts(opts)?
        .wait()   // <- only waits for the local publish to be queued
        ...
    Ok(rustler::types::atom::ok())
}
```

`.wait()` only waits for the local session to finish handing the message off — not for the remote side (the `zenohd` router backing the storage) to actually receive and apply it. `session_get`, on the other hand, is registered as a `DirtyIo` NIF and genuinely waits for a reply from the remote side within a timeout — a real request/response.

If you think of it in Elixir/GenServer terms, `put` behaves like `cast` and `get` behaves like `call`. Firing a `cast` and immediately assuming the effect is visible, then doing a `call` that depends on it, is exactly the kind of race this pattern invites.

This isn't just me — zenoh itself has an open issue tracking the same gap: [eclipse-zenoh/zenoh#2511](https://github.com/eclipse-zenoh/zenoh/issues/2511) ("\[Design\] Acknowledged put: confirmed storage writes via query path vs protocol extension"), still open as of this writing. One line from it sums up the whole thing:

> Zenoh's pub/sub path is fire-and-forget — `session.put()` returns when the message is sent, not when it's stored.

## The fix

A small wrapper: `put`, then `get` the same key right after, and only return once the written payload can actually be read back. Retry at a short interval until a timeout is reached.

```elixir
defmodule ZenohAckPut do
  @default_confirm_timeout_ms 3_000
  @default_confirm_interval_ms 1
  @default_query_timeout_ms 3_000

  def put(session_id, key_expr, payload, put_opts \\ [], confirm_opts \\ []) do
    confirm_timeout_ms =
      Keyword.get(confirm_opts, :confirm_timeout_ms, @default_confirm_timeout_ms)

    confirm_interval_ms =
      Keyword.get(confirm_opts, :confirm_interval_ms, @default_confirm_interval_ms)

    query_timeout_ms = Keyword.get(confirm_opts, :query_timeout_ms, @default_query_timeout_ms)

    with :ok <- Zenohex.Session.put(session_id, key_expr, payload, put_opts) do
      deadline = System.monotonic_time(:millisecond) + confirm_timeout_ms
      confirm(session_id, key_expr, payload, query_timeout_ms, confirm_interval_ms, deadline)
    end
  end

  defp confirm(session_id, key_expr, payload, query_timeout_ms, confirm_interval_ms, deadline) do
    if fetch(session_id, key_expr, query_timeout_ms) == payload do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :not_confirmed}
      else
        Process.sleep(confirm_interval_ms)
        confirm(session_id, key_expr, payload, query_timeout_ms, confirm_interval_ms, deadline)
      end
    end
  end

  defp fetch(session_id, key_expr, query_timeout_ms) do
    case Zenohex.Session.get(session_id, key_expr, query_timeout_ms, consolidation: :latest) do
      {:ok, replies} ->
        case Enum.find(replies, &match?(%Zenohex.Sample{}, &1)) do
          %Zenohex.Sample{payload: found_payload} -> found_payload
          nil -> nil
        end

      {:error, _reason} ->
        nil
    end
  end
end
```

Usage:

```elixir
iex> ZenohAckPut.put(session_id, "key/expr", "payload")
:ok
```

Three possible return values:

- `:ok` — the put succeeded and the read-after-write confirmation also succeeded
- `{:error, :not_confirmed}` — the put itself succeeded, but confirmation didn't land within the timeout (this does *not* mean the write failed — it likely just hasn't shown up yet)
- `{:error, reason}` — the underlying `put` itself failed

Running the same 2000-iteration loop through `ZenohAckPut.put` instead: zero stale reads, zero unconfirmed timeouts.

It's published as a standalone module, along with the reproduction scripts used above and a script that verifies the fix:

- [zenohackput on GitHub](https://github.com/kikuyuta/zenohackput)

Not on Hex yet, so pull it in as a git dependency for now:

```elixir
defp deps do
  [
    {:zenohackput, git: "https://github.com/kikuyuta/zenohackput.git"}
  ]
end
```

## Takeaway

Zenoh's `put` is fire-and-forget while `get` is a real request/response, and a `get` right after a `put` can occasionally return a stale value — a few percent of the time in my measurements. It's a known, currently-unresolved gap upstream. An application-level "put, then confirm with a get" wrapper is enough to close it in practice for use cases (like state handoff) that need read-your-own-writes.

If you're using Zenoh's `put`/`get` for anything where you expect a write to be immediately visible — not just eventually — keep this asymmetry in mind.
