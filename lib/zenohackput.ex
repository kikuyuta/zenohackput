defmodule ZenohAckPut do
  @moduledoc """
  `Zenohex.Session.put/4` is fire-and-forget: it returns `:ok` as soon as
  the message is handed off to the local send queue. It does not guarantee
  that the remote storage (queryable) has actually applied the write yet.
  In Elixir/GenServer terms, `put` behaves like `cast` while `get` behaves
  like `call` — an asymmetry between the two.

  See: https://github.com/eclipse-zenoh/zenoh/issues/2511
  ("[Design] Acknowledged put: confirmed storage writes via query path
  vs protocol extension"). This module is an application-layer,
  no-protocol-changes implementation of that issue's Approach A
  (confirming that a put landed via the existing query/reply path).

  `put/5` issues a `get` against the same key right after `put`, and only
  returns once the written payload can be read back. If it can't be
  confirmed right away, it retries the `get` at a fixed interval, and
  returns `{:error, :not_confirmed}` once the timeout is reached (the
  `put` itself did succeed, so the value will likely show up eventually —
  this return value just makes explicit that the caller couldn't confirm
  it in time).

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
  Takes the same arguments as `Zenohex.Session.put/4`, plus confirmation
  options (`t:confirm_opts/0`).

    - `confirm_timeout_ms` : total time budget to keep retrying confirmation (default 3000ms)
    - `confirm_interval_ms` : retry interval (default 1ms)
    - `query_timeout_ms` : timeout for each individual confirmation `get` call (default 3000ms)

  ## Returns

    - `:ok` : the put succeeded and the read-after-write confirmation also succeeded
    - `{:error, :not_confirmed}` : the put itself succeeded, but confirmation
      didn't land within `confirm_timeout_ms`
    - `{:error, reason}` : `Zenohex.Session.put/4` itself failed
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
