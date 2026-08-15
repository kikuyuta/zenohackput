defmodule ZenohAckPut.MixProject do
  use Mix.Project

  def project do
    [
      app: :zenohackput,
      version: "0.1.0",
      elixir: "~> 1.20",
      description: "A read-after-write confirmed wrapper around Zenohex.Session.put/4.",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:zenohex, "~> 0.9.0"}
    ]
  end
end
