defmodule AmarulaAntiban.MixProject do
  use Mix.Project

  def project do
    [
      app: :amarula_antiban,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "OTP-native anti-ban middleware for Amarula WhatsApp clients, ported from baileys-antiban.",
      package: package(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {AmarulaAntiban.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:amarula, git: "https://github.com/coelhorb/amarula.git", branch: "fork_diff"},
      {:telemetry, "~> 1.2"},
      {:jason, "~> 1.4"},
      {:zoneinfo, "~> 0.1.9"},
      {:req, "~> 0.5", optional: true},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:stream_data, "~> 1.2", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md LICENSE NOTICE),
      links: %{
        "GitHub" => "https://github.com/coelhorb/amarula_antiban",
        "Amarula" => "https://github.com/tubedude/amarula",
        "baileys-antiban (upstream)" => "https://github.com/kobie3717/baileys-antiban"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE", "NOTICE"],
      source_url: "https://github.com/coelhorb/amarula_antiban"
    ]
  end
end
