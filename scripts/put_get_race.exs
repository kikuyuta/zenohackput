# Reproduces and observes, using only Zenoh's put/get, the phenomenon
# where a get right after a put reads back a stale (old) value.
# (This is the motivating reproduction behind ZenohAckPut.)
#
# First, start a router with zenohd_storage.json5:
#
#     zenohd -c zenohd_storage.json5
#
# Run:
#
#     mix run scripts/put_get_race.exs [iterations]

key = "zenohackput/demo/put_get_race"

iterations =
  case System.argv() do
    [n] -> String.to_integer(n)
    _ -> 2000
  end

get_timeout_ms = 3_000
retry_interval_ms = 1

config =
  Zenohex.Config.default()
  |> Zenohex.Config.insert_json5("mode", "client")
  |> then(fn {:ok, c} -> c end)
  |> Zenohex.Config.insert_json5("connect/endpoints", ~s(["tcp/127.0.0.1:7447"]))
  |> then(fn {:ok, c} -> c end)

{:ok, session_id} = Zenohex.Session.open(config)

fetch = fn ->
  {:ok, replies} = Zenohex.Session.get(session_id, key, get_timeout_ms, consolidation: :latest)

  case Enum.find(replies, &match?(%Zenohex.Sample{}, &1)) do
    %Zenohex.Sample{payload: payload} -> payload
    nil -> nil
  end
end

IO.puts("running #{iterations} put→get cycles against #{inspect(key)} ...")

{stale_count, catchup_attempts} =
  Enum.reduce(1..iterations, {0, []}, fn i, {stale_count, catchup_attempts} ->
    payload = Integer.to_string(i)
    :ok = Zenohex.Session.put(session_id, key, payload)

    read = fetch.()

    if read == payload do
      {stale_count, catchup_attempts}
    else
      {attempts, elapsed_ms} =
        Stream.iterate(1, &(&1 + 1))
        |> Enum.reduce_while({0, 0}, fn attempt, {_prev_attempts, elapsed_ms} ->
          Process.sleep(retry_interval_ms)

          if fetch.() == payload do
            {:halt, {attempt, elapsed_ms + retry_interval_ms}}
          else
            {:cont, {attempt, elapsed_ms + retry_interval_ms}}
          end
        end)

      IO.puts(
        "stale read at iteration #{i}: put #{inspect(payload)}, got #{inspect(read)} " <>
          "(caught up after #{attempts} extra get(s), ~#{elapsed_ms}ms)"
      )

      {stale_count + 1, [{attempts, elapsed_ms} | catchup_attempts]}
    end
  end)

Zenohex.Session.close(session_id)

IO.puts("")
IO.puts("=== summary ===")
IO.puts("iterations: #{iterations}")
IO.puts("stale reads: #{stale_count} (#{Float.round(stale_count / iterations * 100, 2)}%)")

if catchup_attempts != [] do
  elapsed_list = Enum.map(catchup_attempts, fn {_attempts, ms} -> ms end)

  IO.puts(
    "catch-up latency (ms): min=#{Enum.min(elapsed_list)} " <>
      "max=#{Enum.max(elapsed_list)} avg=#{Float.round(Enum.sum(elapsed_list) / length(elapsed_list), 2)}"
  )
end
