# ZenohAckPut

`Zenohex.Session.put/4` is fire-and-forget: it returns `:ok` as soon as the
message is handed off to the local send queue. It does not guarantee that
the remote storage (queryable) has actually applied the write yet. In
Elixir/GenServer terms, `put` behaves like `cast` while `get` behaves like
`call` — an asymmetry between the two.

This repository reproduces that asymmetry with a script
(`scripts/put_get_race.exs`), and provides `ZenohAckPut.put/5`, which issues
a `get` against the same key right after `put` and only returns once the
write can be read back (read-after-write confirmation).

See also: [eclipse-zenoh/zenoh#2511 — "\[Design\] Acknowledged put: confirmed
storage writes via query path vs protocol extension"](https://github.com/eclipse-zenoh/zenoh/issues/2511)
(still open as of this writing). `ZenohAckPut` is an application-layer,
no-protocol-changes implementation of that issue's "Approach A".

## Installation

```elixir
def deps do
  [
    {:zenohackput, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
{:ok, session_id} = Zenohex.Session.open(config)

case ZenohAckPut.put(session_id, "key/expr", "payload") do
  :ok ->
    # put succeeded and the read-after-write confirmation succeeded too
    :ok

  {:error, :not_confirmed} ->
    # put itself succeeded, but confirmation didn't land within confirm_timeout_ms
    :error

  {:error, reason} ->
    # Zenohex.Session.put/4 itself failed
    :error
end
```

The confirmation behavior can be tuned via options:

```elixir
ZenohAckPut.put(session_id, "key/expr", "payload", [], 
  confirm_timeout_ms: 3_000,  # total time budget to keep retrying confirmation
  confirm_interval_ms: 1,     # retry interval
  query_timeout_ms: 3_000     # timeout for each individual confirmation get call
)
```

## Reproduction and verification scripts

First, start a router with the `zenohd_storage.json5` bundled in this repo:

```sh
zenohd -c zenohd_storage.json5
```

```sh
# Reproduce the stale-read problem (a get right after put returns an old value)
mix run scripts/put_get_race.exs [iterations]

# Show that open→put→close doesn't solve it either
mix run scripts/put_close_race.exs [iterations]

# Reproduce the hard error you get from a get on a key that was never put,
# and show that ZenohAckPut.put still confirms fine as long as the same
# process reads back what it just wrote
mix run scripts/get_on_unpublished_key.exs

# Show that ZenohAckPut.put eliminates the stale-read problem
mix run scripts/ack_put_verify.exs [iterations]
```

## Test

```sh
zenohd -c zenohd_storage.json5   # run this in another terminal first
mix deps.get
mix test
```
