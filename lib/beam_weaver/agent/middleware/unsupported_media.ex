defmodule BeamWeaver.Agent.Middleware.UnsupportedMedia do
  @moduledoc """
  Replaces images and PDFs the model can't take with a short text notice.

  A thread that holds an image, such as one `read_file` returned, would make
  every later call to a text-only model fail. Before each model call this
  middleware replaces, in user and tool messages, each image and inline PDF
  the called model doesn't take with a notice naming it, such as
  `[report.pdf was left out: this model doesn't take PDFs.]`. Only the request
  changes: the thread keeps the media, so a model that takes it gets it.

  It goes by the model's built-in profile (`image_inputs`, `pdf_inputs`). A
  model with a profile you declared yourself, or with none, keeps its media.

  Every agent and subagent runs it, after its own middleware, so it sees the
  model `ModelFallback` or a router calls.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry

  @impl true
  def name(_middleware), do: :unsupported_media

  @impl true
  def wrap_model_call(_middleware, %ModelRequest{} = request, handler), do: handler.(scrub(request))

  defp scrub(%ModelRequest{} = request) do
    with true <- Enum.any?(request.messages, &has_media?/1),
         [_ | _] = kinds <- unsupported(request.model) do
      ModelRequest.override(request, messages: Enum.map(request.messages, &scrub_message(&1, kinds)))
    else
      _nothing_to_scrub -> request
    end
  end

  defp scrub_message(%Message{role: role, content: content} = message, kinds)
       when role in [:user, :tool] and is_list(content),
       do: %{message | content: Enum.map(content, &scrub_block(&1, kinds))}

  defp scrub_message(message, _kinds), do: message

  defp scrub_block(block, kinds) do
    case media_kind(block) do
      nil -> block
      kind -> if kind in kinds, do: ContentBlock.text(notice(block)), else: block
    end
  end

  defp notice(%ContentBlock.File{filename: name}) when is_binary(name) and name != "",
    do: "[#{name} was left out: this model doesn't take PDFs.]"

  defp notice(%ContentBlock.File{}), do: "[A PDF was left out: this model doesn't take PDFs.]"
  defp notice(%ContentBlock.Image{}), do: "[An image was left out: this model doesn't take images.]"

  # A PDF by URL or file id is the provider's to fetch; only inline data is
  # left out.
  defp media_kind(%ContentBlock.Image{}), do: :image
  defp media_kind(%ContentBlock.File{mime_type: "application/pdf", data: data}) when is_binary(data), do: :pdf
  defp media_kind(_block), do: nil

  defp has_media?(%Message{role: role, content: content}) when role in [:user, :tool] and is_list(content),
    do: Enum.any?(content, &media_kind/1)

  defp has_media?(_message), do: false

  # The media the model's built-in profile says it doesn't take. Profile
  # fields default to false, so a profile declared by hand, which may leave
  # them out, says nothing; nor does the placeholder for an unknown model.
  defp unsupported(model) do
    case builtin_profile(model) do
      %Profile{} = profile ->
        for {kind, field} <- [image: :image_inputs, pdf: :pdf_inputs], Map.get(profile, field) == false, do: kind

      nil ->
        []
    end
  end

  defp builtin_profile(model) do
    with %Profile{provider: provider, id: id} = profile when is_atom(provider) and is_binary(id) <- model_profile(model),
         {:ok, ^profile} <- ProfileRegistry.fetch(provider, id),
         true <- profile.extra[:unknown] != true do
      profile
    else
      _other -> nil
    end
  end

  # Wrappers such as `Models.cached/3` keep the model they wrap in `:model`.
  defp model_profile(%{profile: %Profile{} = profile}), do: profile
  defp model_profile(%{model: %{} = model}), do: model_profile(model)
  defp model_profile(_model), do: nil
end
