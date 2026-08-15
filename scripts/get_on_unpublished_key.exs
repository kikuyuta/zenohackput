# put_get_race.exs / put_close_race.exs は「古い値が返ってきてしまう」
# (stale read) パターンの再現だったが、これは別のパターン: 一度も put
# されたことのないキーに get すると、`{:ok, []}` ではなく
# `{:error, "... channel is empty and closed"}` というハードエラーに
# なることがある、という現象の再現。
#
# 素の Zenohex.Session.get はこれをそのままエラーとして返すが、
# ZenohAckPut.put はこの状況でもクラッシュせず (内部の get 失敗を
# "まだ確認できていない" として扱い put 後にリトライするだけなので)、
# 書き込んだ本人が読み返す分には問題なく :ok を返すことを確認する。
#
# 事前に zenohd_storage.json5 でルーターを起動しておくこと:
#
#     zenohd -c zenohd_storage.json5
#
# 実行:
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
