defmodule BeamWeaver.Anthropic.ChatModel.ModelResolution do
  @moduledoc false

  alias BeamWeaver.Anthropic.Error
  alias BeamWeaver.Models.ProfileRegistry

  @spec resolve(BeamWeaver.Anthropic.ChatModel.t(), keyword()) ::
          {:ok, BeamWeaver.Anthropic.ChatModel.t()} | {:error, Error.t()}
  def resolve(%{model: current_model} = model, opts) do
    requested_model = Keyword.get(opts, :model, current_model)

    cond do
      requested_model == current_model ->
        {:ok, model}

      not is_binary(requested_model) ->
        {:error,
         Error.new(:invalid_model, "Anthropic model identifier must be a string", %{
           provider: :anthropic,
           model: requested_model
         })}

      true ->
        case ProfileRegistry.fetch(:anthropic, requested_model) do
          {:ok, profile} ->
            {:ok,
             %{
               model
               | model: requested_model,
                 profile: profile,
                 max_tokens: capped_max_tokens(model, profile, opts)
             }}

          {:error, error} ->
            {:error, Error.new(error.type, error.message, error.details)}
        end
    end
  end

  defp capped_max_tokens(model, profile, opts) do
    configured = Map.get(model, :max_tokens)
    profile_limit = Map.get(profile, :max_output_tokens)

    cond do
      Keyword.has_key?(opts, :max_tokens) -> configured
      is_integer(configured) and is_integer(profile_limit) -> min(configured, profile_limit)
      is_integer(profile_limit) -> profile_limit
      true -> configured
    end
  end
end
