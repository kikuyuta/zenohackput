defmodule ZenohAckPutTest do
  use ExUnit.Case
  doctest ZenohAckPut

  # These tests need a real zenohd router running with the storage config
  # bundled in this repo:
  #
  #     zenohd -c zenohd_storage.json5
  #
  # They are ordinary (not tagged) integration tests, since ZenohAckPut only
  # makes sense against a real Zenoh session/storage.

  setup do
    config =
      Zenohex.Config.default()
      |> Zenohex.Config.insert_json5("mode", "client")
      |> then(fn {:ok, c} -> c end)
      |> Zenohex.Config.insert_json5("connect/endpoints", ~s(["tcp/127.0.0.1:7447"]))
      |> then(fn {:ok, c} -> c end)

    {:ok, session_id} = Zenohex.Session.open(config)
    on_exit(fn -> Zenohex.Session.close(session_id) end)

    %{session_id: session_id}
  end

  test "put/3 confirms the value is readable via get afterwards", %{session_id: session_id} do
    key = "zenohackput/test/#{System.unique_integer([:positive])}"

    assert :ok = ZenohAckPut.put(session_id, key, "hello")

    {:ok, replies} = Zenohex.Session.get(session_id, key, 3_000, consolidation: :latest)
    assert [%Zenohex.Sample{payload: "hello"}] = replies
  end

  test "put/5 returns {:error, :not_confirmed} when nothing stores the key", %{
    session_id: session_id
  } do
    # zenohd_storage.json5 only backs "zenohackput/**" with a storage, so a
    # key outside that prefix is accepted by put/2 (Zenoh doesn't require a
    # matching storage to publish) but can never be read back via get/4,
    # making the confirmation deterministically time out.
    key = "no_storage_backs_this/#{System.unique_integer([:positive])}"

    assert {:error, :not_confirmed} =
             ZenohAckPut.put(session_id, key, "hello", [], confirm_timeout_ms: 50)
  end
end
