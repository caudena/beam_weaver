defmodule Mix.Tasks.BeamWeaver.Models.Profiles do
  @moduledoc """
  Prints deterministic model profile data.

      mix beam_weaver.models.profiles
      mix beam_weaver.models.profiles --provider openai
      mix beam_weaver.models.profiles --json
      mix beam_weaver.models.profiles --refresh --provider anthropic --data-dir priv/model_profiles
      mix beam_weaver.models.profiles --refresh --provider anthropic --data-dir priv/model_profiles --source-json path/to/api.json --yes

  `--refresh` writes a local `profiles.json` artifact from models.dev-style
  provider data. Use `--source-json` for a checked-in or downloaded source file,
  and `--yes` to allow writes outside the current directory without an
  interactive prompt.
  """

  use Mix.Task

  alias BeamWeaver.JSON
  alias BeamWeaver.Models.ProfileRefresh
  alias BeamWeaver.Models.ProfileRegistry

  @shortdoc "Prints BeamWeaver model profiles"

  @impl true
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args,
        strict: [
          provider: :string,
          json: :boolean,
          refresh: :boolean,
          data_dir: :string,
          source_json: :string,
          yes: :boolean
        ]
      )

    if opts[:refresh] do
      Mix.Task.run("app.start")
      refresh_profiles!(opts)
    else
      print_profiles!(opts)
    end
  end

  defp refresh_profiles!(opts) do
    provider = opts[:provider] || Mix.raise("--provider is required with --refresh")
    data_dir = opts[:data_dir] || Mix.raise("--data-dir is required with --refresh")

    refresh_opts =
      [
        force: opts[:yes] == true,
        confirm_fun: fn target, current ->
          Mix.shell().yes?("Write model profiles outside current directory?\nCurrent: #{current}\nTarget: #{target}")
        end
      ]
      |> maybe_put(:source_path, opts[:source_json])

    case ProfileRefresh.refresh(provider, data_dir, refresh_opts) do
      {:ok, %{path: path, profiles: profiles}} ->
        Mix.shell().info("Refreshed #{length(profiles)} profiles into #{path}")

      {:error, error} ->
        Mix.raise(error.message)
    end
  end

  defp print_profiles!(opts) do
    profiles =
      case opts[:provider] do
        nil -> ProfileRegistry.all()
        provider -> ProfileRegistry.profiles(provider_atom!(provider))
      end

    if opts[:json] do
      profiles
      |> Enum.map(&profile_json/1)
      |> JSON.encode!(pretty: true)
      |> Mix.shell().info()
    else
      profiles
      |> Enum.map_join("\n", &profile_line/1)
      |> Mix.shell().info()
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp profile_line(profile) do
    capabilities =
      [
        {:responses, profile.responses_api},
        {:chat_completions, profile.chat_completions_api},
        {:tools, profile.tool_calling},
        {:tool_call_streaming, profile.tool_call_streaming},
        {:structured, profile.structured_output},
        {:streaming, profile.streaming},
        {:reasoning, profile.reasoning_output}
      ]
      |> Enum.flat_map(fn
        {name, true} -> [Atom.to_string(name)]
        {_name, _value} -> []
      end)
      |> Enum.join(",")

    "#{profile.provider}:#{profile.id} #{profile.name} [#{capabilities}]"
  end

  defp profile_json(profile) do
    profile
    |> Map.from_struct()
    |> normalize_json()
  end

  defp normalize_json(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_json(value)} end)
  end

  defp normalize_json(values) when is_list(values), do: Enum.map(values, &normalize_json/1)
  defp normalize_json(nil), do: nil
  defp normalize_json(value) when is_boolean(value), do: value
  defp normalize_json(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json(value), do: value

  defp provider_atom!(provider) do
    Enum.find(ProfileRegistry.providers(), &(Atom.to_string(&1) == provider)) ||
      Mix.raise("Unknown provider #{inspect(provider)}")
  end
end
