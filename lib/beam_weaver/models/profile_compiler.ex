defmodule BeamWeaver.Models.ProfileCompiler do
  @moduledoc false

  import BeamWeaver.MapShape, only: [reject_nil_values: 1]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile

  @spec compile_provider(map(), String.t() | atom()) :: {:ok, [Profile.t()]} | {:error, Error.t()}
  def compile_provider(models_dev_response, provider) when is_map(models_dev_response) do
    provider_key = to_string(provider)

    case models_dev_response[provider_key] do
      %{} = provider_data ->
        provider_atom = provider_atom(provider_key)

        profiles =
          (provider_data["models"] || %{})
          |> Enum.sort()
          |> Enum.map(fn {model_id, model_data} ->
            model_data
            |> model_data_to_profile()
            |> Map.merge(%{provider: provider_atom, id: model_id})
            |> Profile.new()
          end)

        {:ok, profiles}

      _missing ->
        {:error,
         Error.new(:missing_profile_provider, "models.dev response has no provider", %{
           provider: provider_key
         })}
    end
  end

  defp model_data_to_profile(model_data) when is_map(model_data) do
    limit = model_data["limit"] || %{}
    modalities = model_data["modalities"] || %{}
    input_modalities = modalities["input"] || []
    output_modalities = modalities["output"] || []

    %{
      name: model_data["name"],
      status: model_data["status"],
      release_date: model_data["release_date"],
      last_updated: model_data["last_updated"],
      open_weights: model_data["open_weights"],
      context_limit_kind: :shared_input_output,
      max_context_tokens: limit["context"],
      max_input_tokens: limit["context"],
      max_output_tokens: limit["output"],
      text_inputs: "text" in input_modalities,
      image_inputs: "image" in input_modalities,
      audio_inputs: "audio" in input_modalities,
      pdf_inputs: "pdf" in input_modalities or model_data["pdf_inputs"] == true,
      video_inputs: "video" in input_modalities,
      text_outputs: "text" in output_modalities,
      image_outputs: "image" in output_modalities,
      audio_outputs: "audio" in output_modalities,
      video_outputs: "video" in output_modalities,
      reasoning_output: model_data["reasoning"],
      tool_calling: model_data["tool_call"],
      tool_call_streaming: model_data["tool_call_streaming"],
      tool_choice: model_data["tool_choice"],
      structured_output: model_data["structured_output"],
      structured_output_with_tools: model_data["structured_output_with_tools"],
      structured_output_max_schema_bytes: model_data["structured_output_max_schema_bytes"],
      structured_output_max_schema_properties: model_data["structured_output_max_schema_properties"],
      attachment: model_data["attachment"],
      temperature: model_data["temperature"],
      image_url_inputs: model_data["image_url_inputs"],
      image_tool_message: model_data["image_tool_message"],
      pdf_tool_message: model_data["pdf_tool_message"]
    }
    |> reject_nil_values()
  end

  defp provider_atom(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> provider
  end
end
