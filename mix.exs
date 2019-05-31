defmodule BroadwayOts.MixProject do
  use Mix.Project

  def project do
    [
      app: :broadway_ots,
      version: "0.1.0",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {BroadwayOts.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:broadway, "~> 0.3"},
      #       {:ex_aliyun_ots, "~> 0.2"},
      {:ex_aliyun_ots, git: "https://github.com/xinz/ex_aliyun_ots.git", branch: "tunnel"}
    ]
  end
end
