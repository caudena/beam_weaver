defmodule BeamWeaver.TextSplitter.Character do
  @moduledoc false
  defstruct BeamWeaver.TextSplitter.Shared.common_fields()

  def new(opts \\ []), do: struct(__MODULE__, BeamWeaver.TextSplitter.Shared.normalize_opts(opts))

  def split_text(%__MODULE__{} = splitter, text),
    do: BeamWeaver.TextSplitter.Shared.split_text(splitter, text)

  def split_document(splitter, document),
    do: BeamWeaver.TextSplitter.Shared.split_document(splitter, document)
end

defmodule BeamWeaver.TextSplitter.RecursiveCharacter do
  @moduledoc false
  defstruct BeamWeaver.TextSplitter.Shared.common_fields()

  def new(opts \\ []), do: struct(__MODULE__, BeamWeaver.TextSplitter.Shared.normalize_opts(opts))

  def split_text(%__MODULE__{} = splitter, text),
    do: BeamWeaver.TextSplitter.Shared.split_text(splitter, text)

  def split_document(splitter, document),
    do: BeamWeaver.TextSplitter.Shared.split_document(splitter, document)
end

defmodule BeamWeaver.TextSplitter.Markdown do
  @moduledoc false
  defstruct BeamWeaver.TextSplitter.Shared.common_fields()

  @separators ["\n## ", "\n### ", "\n#### ", "\n\n", "\n", " ", ""]
  def new(opts \\ []),
    do:
      struct(
        __MODULE__,
        BeamWeaver.TextSplitter.Shared.normalize_opts(opts, separators: @separators)
      )

  def split_text(%__MODULE__{} = splitter, text),
    do: BeamWeaver.TextSplitter.Shared.split_text(splitter, text)

  def split_document(splitter, document),
    do: BeamWeaver.TextSplitter.Shared.split_document(splitter, document)
end

defmodule BeamWeaver.TextSplitter.HTML do
  @moduledoc false
  defstruct BeamWeaver.TextSplitter.Shared.common_fields()

  @separators ["</p>", "</div>", "<br", "\n\n", "\n", " ", ""]
  def new(opts \\ []),
    do:
      struct(
        __MODULE__,
        BeamWeaver.TextSplitter.Shared.normalize_opts(opts, separators: @separators)
      )

  def split_text(%__MODULE__{} = splitter, text),
    do: BeamWeaver.TextSplitter.Shared.split_text(splitter, text)

  def split_document(splitter, document),
    do: BeamWeaver.TextSplitter.Shared.split_document(splitter, document)
end

defmodule BeamWeaver.TextSplitter.LaTeX do
  @moduledoc false
  defstruct BeamWeaver.TextSplitter.Shared.common_fields()

  @separators ["\n\\section", "\n\\subsection", "\n\\begin", "\n\n", "\n", " ", ""]
  def new(opts \\ []),
    do:
      struct(
        __MODULE__,
        BeamWeaver.TextSplitter.Shared.normalize_opts(opts, separators: @separators)
      )

  def split_text(%__MODULE__{} = splitter, text),
    do: BeamWeaver.TextSplitter.Shared.split_text(splitter, text)

  def split_document(splitter, document),
    do: BeamWeaver.TextSplitter.Shared.split_document(splitter, document)
end

defmodule BeamWeaver.TextSplitter.Code do
  @moduledoc false
  defstruct BeamWeaver.TextSplitter.Shared.common_fields()

  @separators ["\n\n", "\ndef ", "\nclass ", "\nfunction ", "\nconst ", "\nlet ", "\n", " ", ""]
  def new(opts \\ []),
    do:
      struct(
        __MODULE__,
        BeamWeaver.TextSplitter.Shared.normalize_opts(opts, separators: @separators)
      )

  def split_text(%__MODULE__{} = splitter, text),
    do: BeamWeaver.TextSplitter.Shared.split_text(splitter, text)

  def split_document(splitter, document),
    do: BeamWeaver.TextSplitter.Shared.split_document(splitter, document)
end

defmodule BeamWeaver.TextSplitter.Python do
  @moduledoc false
  defstruct BeamWeaver.TextSplitter.Shared.common_fields()

  @separators ["\nclass ", "\ndef ", "\n\tdef ", "\n\n", "\n", " ", ""]
  def new(opts \\ []),
    do:
      struct(
        __MODULE__,
        BeamWeaver.TextSplitter.Shared.normalize_opts(opts, separators: @separators)
      )

  def split_text(%__MODULE__{} = splitter, text),
    do: BeamWeaver.TextSplitter.Shared.split_text(splitter, text)

  def split_document(splitter, document),
    do: BeamWeaver.TextSplitter.Shared.split_document(splitter, document)
end

defmodule BeamWeaver.TextSplitter.JSX do
  @moduledoc false
  defstruct BeamWeaver.TextSplitter.Shared.common_fields()

  @separators ["\nfunction ", "\nconst ", "\nexport ", "\nreturn ", "\n\n", "\n", " ", ""]
  def new(opts \\ []),
    do:
      struct(
        __MODULE__,
        BeamWeaver.TextSplitter.Shared.normalize_opts(opts, separators: @separators)
      )

  def split_text(%__MODULE__{} = splitter, text),
    do: BeamWeaver.TextSplitter.Shared.split_text(splitter, text)

  def split_document(splitter, document),
    do: BeamWeaver.TextSplitter.Shared.split_document(splitter, document)
end

defmodule BeamWeaver.TextSplitter.Token do
  @moduledoc false
  defstruct BeamWeaver.TextSplitter.Shared.common_fields() ++
              [tokenizer: %BeamWeaver.Tokenizer.Approximate{}]

  def new(opts \\ []), do: struct(__MODULE__, BeamWeaver.TextSplitter.Shared.normalize_opts(opts))

  def split_text(%__MODULE__{} = splitter, text),
    do: BeamWeaver.TextSplitter.Shared.token_split_text(splitter, text)

  def split_document(splitter, document),
    do: BeamWeaver.TextSplitter.Shared.token_split_document(splitter, document)
end
