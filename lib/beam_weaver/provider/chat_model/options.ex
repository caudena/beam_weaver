defmodule BeamWeaver.Provider.ChatModel.Options do
  @moduledoc false

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry

  @spec keyword_options(keyword() | map()) :: keyword()
  def keyword_options(opts) when is_map(opts), do: Map.to_list(opts)
  def keyword_options(opts), do: opts

  @spec profile_option(keyword(), atom(), String.t()) :: Profile.t()
  def profile_option(opts, provider, model) do
    case Keyword.fetch(opts, :profile) do
      {:ok, profile} ->
        Profile.new(profile)

      :error ->
        case ProfileRegistry.fetch(provider, model) do
          {:ok, profile} -> profile
          {:error, error} -> raise ArgumentError, profile_error_message(error)
        end
    end
  end

  defp profile_error_message(%{message: message, details: details}) when is_map(details) do
    case BeamWeaver.MapAccess.get(details, :expected) do
      nil -> message
      expected -> "#{message}; use #{expected}"
    end
  end

  defp profile_error_message(%{message: message}), do: message

  @spec should_stream?(map(), keyword()) :: boolean()
  def should_stream?(model, opts) when is_map(model) do
    Keyword.get(opts, :stream, Map.get(model, :streaming, false)) == true
  end
end
