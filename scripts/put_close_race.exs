# put_get_race.exs の追加実験。
#
# 「同じセッションで put した直後に get する」のではなく、
# 「毎回 open → put → close して、書き込み用セッションを完全に閉じてから
#   (別の読み取り専用セッションで) get する」パターンでも stale read が
# 起こるかどうかを検証する (close はローカルの送信バッファを掃かせるだけで、
# リモートの storage が反映し終えたことの確認にはならない、という仮説の検証)。
#
# 事前に zenohd_storage.json5 でルーターを起動しておくこと:
#
#     zenohd -c zenohd_storage.json5
#
# 実行:
#
#     mix run scripts/put_close_race.exs [iterations]

key = "zenohackput/demo/put_close_race"

iterations =
  case System.argv() do
    [n] -> String.to_integer(n)
    _ -> 300
  end

get_timeout_ms = 3_000
retry_interval_ms = 1

config =
  Zenohex.Config.default()
  |> Zenohex.Config.insert_json5("mode", "client")
  |> then(fn {:ok, c} -> c end)
  |> Zenohex.Config.insert_json5("connect/endpoints", ~s(["tcp/127.0.0.1:7447"]))
  |> then(fn {:ok, c} -> c end)

{:ok, reader_session_id} = Zenohex.Session.open(config)

fetch = fn ->
  {:ok, replies} =
    Zenohex.Session.get(reader_session_id, key, get_timeout_ms, consolidation: :latest)

  case Enum.find(replies, &match?(%Zenohex.Sample{}, &1)) do
    %Zenohex.Sample{payload: payload} -> payload
    nil -> nil
  end
end

IO.puts("running #{iterations} (open→put→close)→get cycles against #{inspect(key)} ...")

{stale_count, catchup} =
  Enum.reduce(1..iterations, {0, []}, fn i, {stale_count, catchup} ->
    payload = Integer.to_string(i)

    {:ok, writer_session_id} = Zenohex.Session.open(config)
    :ok = Zenohex.Session.put(writer_session_id, key, payload)
    :ok = Zenohex.Session.close(writer_session_id)

    read = fetch.()

    if read == payload do
      {stale_count, catchup}
    else
      {attempts, elapsed_ms} =
        Stream.iterate(1, &(&1 + 1))
        |> Enum.reduce_while({0, 0}, fn attempt, {_prev, elapsed_ms} ->
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

      {stale_count + 1, [{attempts, elapsed_ms} | catchup]}
    end
  end)

Zenohex.Session.close(reader_session_id)

IO.puts("")
IO.puts("=== summary (open→put→close pattern) ===")
IO.puts("iterations: #{iterations}")
IO.puts("stale reads: #{stale_count} (#{Float.round(stale_count / iterations * 100, 2)}%)")

if catchup != [] do
  elapsed_list = Enum.map(catchup, fn {_attempts, ms} -> ms end)

  IO.puts(
    "catch-up latency (ms): min=#{Enum.min(elapsed_list)} " <>
      "max=#{Enum.max(elapsed_list)} avg=#{Float.round(Enum.sum(elapsed_list) / length(elapsed_list), 2)}"
  )
end
