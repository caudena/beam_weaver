defmodule BeamWeaver.Prompt.Loader do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Prompt
  alias BeamWeaver.Prompt.Loader.Codec
  alias BeamWeaver.Prompt.Loader.Files

  def load(path, opts \\ []) do
    path = Kernel.to_string(path)

    with :ok <- Files.reject_hub_path(path),
         path <- Path.expand(path),
         {:ok, contents} <- Files.read_file(path),
         {:ok, config} <- Codec.decode(path, contents) do
      from_config(config, Keyword.put_new(opts, :base_dir, Path.dirname(path)))
    end
  end

  def load!(path, opts \\ []) do
    case load(path, opts) do
      {:ok, prompt} -> prompt
      {:error, %Error{} = error} -> raise ArgumentError, error.message
    end
  end

  def from_file(path, opts \\ []) do
    with {:ok, template} <- Files.read_text_file(Path.expand(Kernel.to_string(path)), opts) do
      {:ok,
       Prompt.string(template,
         partials: Keyword.get(opts, :partials, %{}),
         template_format: Keyword.get(opts, :template_format, :simple),
         validate?: Keyword.get(opts, :validate?, false)
       )}
    end
  end

  def save(prompt, path, opts \\ []) do
    path = Path.expand(Kernel.to_string(path))

    with {:ok, spec} <- Prompt.Spec.to_spec(prompt),
         {:ok, value} <- Codec.json_value(spec),
         {:ok, encoded} <- Codec.encode(path, value, opts) do
      path
      |> Path.dirname()
      |> File.mkdir_p!()

      case File.write(path, [encoded, ?\n]) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error,
           Error.new(:prompt_save_error, "prompt file could not be written", %{
             path: path,
             reason: reason
           })}
      end
    end
  end

  def from_config(config), do: from_config(config, [])

  def from_config(%{"type" => _type} = spec, _opts) do
    build_native_spec(spec)
  end

  def from_config(config, _opts) when is_map(config) do
    {:error,
     Error.new(:invalid_prompt_spec, "prompt specs must include a native type field", %{
       config: config
     })}
  end

  def from_config(config, _opts) do
    {:error, Error.new(:invalid_prompt_spec, "prompt config must be a map", %{config: config})}
  end

  defp build_native_spec(spec) do
    Prompt.Spec.from_spec(spec)
  rescue
    error ->
      {:error,
       Error.new(:invalid_prompt_spec, "native prompt spec could not be loaded", %{
         reason: Exception.message(error)
       })}
  end
end
