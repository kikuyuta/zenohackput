# ZenohAckPut

`Zenohex.Session.put/4` は fire-and-forget で、ローカルの送信キューに載せた
時点で `:ok` を返す。リモートの storage (queryable) が実際に値を反映し
終えたことまでは保証しない。Elixir の GenServer で言えば、`put` は `cast`、
`get` は `call` に相当する非対称性がある。

このリポジトリは、この非対称性が実際に観測できることをスクリプトで再現した
上で (`scripts/put_get_race.exs`)、put の直後に同じ key へ get して
read-after-write を確認してから返る `ZenohAckPut.put/5` を提供する。

参考: [eclipse-zenoh/zenoh#2511 — "\[Design\] Acknowledged put: confirmed
storage writes via query path vs protocol extension"](https://github.com/eclipse-zenoh/zenoh/issues/2511)
(まだ Open。`ZenohAckPut` はこの issue の Approach A を、プロトコル変更なしに
アプリケーション層で自前実装したもの)

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
    # put が成功し、read-after-write の確認も取れた
    :ok

  {:error, :not_confirmed} ->
    # put 自体は成功したが、confirm_timeout_ms 以内に確認が取れなかった
    :error

  {:error, reason} ->
    # Zenohex.Session.put/4 自体が失敗した
    :error
end
```

確認まわりの挙動はオプションで調整できる:

```elixir
ZenohAckPut.put(session_id, "key/expr", "payload", [], 
  confirm_timeout_ms: 3_000,  # 確認をリトライし続ける合計時間
  confirm_interval_ms: 1,     # リトライ間隔
  query_timeout_ms: 3_000     # 確認用の各 get 呼び出し自体のタイムアウト
)
```

## 現象の再現・検証スクリプト

事前に、このリポジトリに同梱の `zenohd_storage.json5` でルーターを起動する:

```sh
zenohd -c zenohd_storage.json5
```

```sh
# 素の put/get で stale read が起こることを再現する
mix run scripts/put_get_race.exs [iterations]

# open→put→close でも解決しないことを確認する
mix run scripts/put_close_race.exs [iterations]

# ZenohAckPut.put が stale read を解消することを確認する
mix run scripts/ack_put_verify.exs [iterations]
```

## Test

```sh
zenohd -c zenohd_storage.json5   # 別ターミナルで起動しておく
mix deps.get
mix test
```
