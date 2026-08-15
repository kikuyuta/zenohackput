# ZenohAckPut.put/3 が put_get_race.exs で観測される stale read を
# 実際に解消するかを検証するスクリプト。
#
# 事前に zenohd_storage.json5 でルーターを起動しておくこと:
#
#     zenohd -c zenohd_storage.json5
#
# 実行:
#
#     mix run scripts/ack_put_verify.exs [iterations]

key = "zenohackput/demo/ack_put_verify"

iterations =
  case System.argv() do
    [n] -> String.to_integer(n)
    _ -> 2000
  end

config =
  Zenohex.Config.default()
  |> Zenohex.Config.insert_json5("mode", "client")
  |> then(fn {:ok, c} -> c end)
  |> Zenohex.Config.insert_json5("connect/endpoints", ~s(["tcp/127.0.0.1:7447"]))
  |> then(fn {:ok, c} -> c end)

{:ok, session_id} = Zenohex.Session.open(config)

fetch = fn ->
  {:ok, replies} = Zenohex.Session.get(session_id, key, 3_000, consolidation: :latest)

  case Enum.find(replies, &match?(%Zenohex.Sample{}, &1)) do
    %Zenohex.Sample{payload: payload} -> payload
    nil -> nil
  end
end

IO.puts("running #{iterations} ZenohAckPut.put→get cycles against #{inspect(key)} ...")

{stale_count, not_confirmed_count} =
  Enum.reduce(1..iterations, {0, 0}, fn i, {stale_count, not_confirmed_count} ->
    payload = Integer.to_string(i)

    case ZenohAckPut.put(session_id, key, payload) do
      :ok ->
        read = fetch.()

        if read == payload do
          {stale_count, not_confirmed_count}
        else
          IO.puts(
            "unexpected stale read right after ZenohAckPut.put confirmed at iteration #{i}: " <>
              "put #{inspect(payload)}, got #{inspect(read)}"
          )

          {stale_count + 1, not_confirmed_count}
        end

      {:error, :not_confirmed} ->
        IO.puts("iteration #{i}: not confirmed within timeout")
        {stale_count, not_confirmed_count + 1}
    end
  end)

Zenohex.Session.close(session_id)

IO.puts("")
IO.puts("=== summary (ZenohAckPut.put) ===")
IO.puts("iterations: #{iterations}")
IO.puts("stale reads after confirmed put: #{stale_count}")
IO.puts("not_confirmed within timeout: #{not_confirmed_count}")
