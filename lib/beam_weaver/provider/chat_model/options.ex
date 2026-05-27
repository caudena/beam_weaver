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

  @spec profile_error_message(term()) :: String.t()
  def profile_error_message(%{message: message, details: details}) when is_map(details) do
    case BeamWeaver.MapAccess.get(details, :expected) do
      nil -> message
      expected -> "#{message}; use #{expected}"
    end
  end

  def profile_error_message(%{message: message}), do: message
  def profile_error_message(error), do: inspect(error)

  @spec should_stream?(map(), keyword()) :: boolean()
  def should_stream?(model, opts) when is_map(model) do
    Keyword.get(opts, :stream, Map.get(model, :streaming, false)) == true
  end

  @spec model_id(map()) :: String.t() | nil
  def model_id(%{model: model}), do: model

  @spec profile(map()) :: Profile.t() | nil
  def profile(%{profile: profile}), do: profile

  @spec put_present(keyword(), atom(), term()) :: keyword()
  def put_present(opts, key, value), do: BeamWeaver.MapShape.put_present(opts, key, value)

  @spec default_response_header_opt(map(), keyword()) :: keyword()
  def default_response_header_opt(%{include_response_headers: include_response_headers}, opts) do
    Keyword.put_new(opts, :include_response_headers, include_response_headers)
  end
end
