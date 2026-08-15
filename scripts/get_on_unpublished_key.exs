# put_get_race.exs / put_close_race.exs reproduce the "stale read" pattern
# (an old value comes back). This script reproduces a different pattern:
# a get against a key that has never been put can return a hard error
# (`{:error, "... channel is empty and closed"}`) instead of `{:ok, []}`.
#
# Plain Zenohex.Session.get just returns that error as-is, but
# ZenohAckPut.put doesn't crash on it (any get failure inside its confirm
# loop is treated as "not confirmed yet" and simply retried), so it still
# returns :ok as long as the same process reads back what it just wrote.
#
# First, start a router with zenohd_storage.json5:
#
#     zenohd -c zenohd_storage.json5
#
# Run:
#
#     mix run scripts/get_on_unpublished_key.exs

config =
  Zenohex.Config.default()
  |> Zenohex.Config.insert_json5("mode", "client")
  |> then(fn {:ok, c} -> c end)
  |> Zenohex.Config.insert_json5("connect/endpoints", ~s(["tcp/127.0.0.1:7447"]))
  |> then(fn {:ok, c} -> c end)

{:ok, session_id} = Zenohex.Session.open(config)

fresh_key = fn -> "zenohackput/demo/never_published_#{System.unique_integer([:positive])}" end

IO.puts("--- raw Zenohex.Session.get on a never-published key ---")
key1 = fresh_key.()
IO.inspect(Zenohex.Session.get(session_id, key1, 3_000, consolidation: :latest), label: "get(#{key1})")

IO.puts("")
IO.puts("--- ZenohAckPut.put on a (different) never-published key ---")
key2 = fresh_key.()
IO.inspect(ZenohAckPut.put(session_id, key2, "hello"), label: "ZenohAckPut.put(#{key2})")

IO.inspect(Zenohex.Session.get(session_id, key2, 3_000, consolidation: :latest),
  label: "get(#{key2}) after ZenohAckPut.put"
)

Zenohex.Session.close(session_id)
