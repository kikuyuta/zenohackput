defmodule ZenohAckPut do
  @moduledoc """
  `Zenohex.Session.put/4` は fire-and-forget であり、ローカルの送信キューに
  載せた時点で `:ok` を返す。リモートの storage (queryable) が実際に値を
  反映し終えたことまでは保証しない。Elixir の GenServer で言えば、
  `put` は `cast`、`get` は `call` に相当する非対称性がある。

  参考: https://github.com/eclipse-zenoh/zenoh/issues/2511
  ("[Design] Acknowledged put: confirmed storage writes via query path
  vs protocol extension")。本モジュールはこの issue が言う Approach A
  (put の反映を、既存の query/reply 経由で確認する) を、プロトコル変更なしに
  アプリケーション層で自前実装したもの。

  `put/5` は put した直後に同じ key へ get を発行し、書き込んだ payload が
  読み返せることを確認してから返る。すぐには確認できなくても、一定間隔で
  get をリトライし、タイムアウトすると `{:error, :not_confirmed}` を返す
  (put 自体は成功しているので、値はそのうち反映される可能性が高いが、
  呼び出し側がすぐには確認できなかった、という状態を明示的に返す)。

  ## Example

      {:ok, session_id} = Zenohex.Session.open()
      ZenohAckPut.put(session_id, "key/expr", "payload")
      #=> :ok
  """

  @default_confirm_timeout_ms 3_000
  @default_confirm_interval_ms 1
  @default_query_timeout_ms 3_000

  @type confirm_opts :: [
          confirm_timeout_ms: non_neg_integer(),
          confirm_interval_ms: non_neg_integer(),
          query_timeout_ms: non_neg_integer()
        ]

  @doc """
  `Zenohex.Session.put/4` と同じ引数に加え、確認まわりのオプション
  (`t:confirm_opts/0`) を受け取る。

    - `confirm_timeout_ms` : 確認をリトライし続ける合計時間 (デフォルト 3000ms)
    - `confirm_interval_ms` : リトライ間隔 (デフォルト 1ms)
    - `query_timeout_ms` : 確認用の各 get 呼び出し自体のタイムアウト (デフォルト 3000ms)

  ## Returns

    - `:ok` : put が成功し、read-after-write の確認も取れた
    - `{:error, :not_confirmed}` : put 自体は成功したが、
      `confirm_timeout_ms` 以内に確認が取れなかった
    - `{:error, reason}` : `Zenohex.Session.put/4` 自体が失敗した
  """
  @spec put(
          Zenohex.Session.id(),
          String.t(),
          binary(),
          Zenohex.Session.put_opts(),
          confirm_opts()
        ) :: :ok | {:error, term()}
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
