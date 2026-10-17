for {name, defaults} <- [
      Character: [],
      RecursiveCharacter: [],
      Markdown: [separators: ["\n## ", "\n### ", "\n#### ", "\n\n", "\n", " ", ""]],
      HTML: [separators: ["</p>", "</div>", "<br", "\n\n", "\n", " ", ""]],
      LaTeX: [separators: ["\n\\section", "\n\\subsection", "\n\\begin", "\n\n", "\n", " ", ""]],
      Code: [separators: ["\n\n", "\ndef ", "\nclass ", "\nfunction ", "\nconst ", "\nlet ", "\n", " ", ""]],
      Python: [separators: ["\nclass ", "\ndef ", "\n\tdef ", "\n\n", "\n", " ", ""]],
      JSX: [separators: ["\nfunction ", "\nconst ", "\nexport ", "\nreturn ", "\n\n", "\n", " ", ""]]
    ] do
  defmodule Module.concat(BeamWeaver.TextSplitter, name) do
    @moduledoc false
    alias BeamWeaver.TextSplitter.Shared

    @defaults defaults
    defstruct Shared.common_fields()

    def new(opts), do: struct(__MODULE__, Shared.normalize_opts(opts, @defaults))
    def split_text(%__MODULE__{} = splitter, text), do: Shared.split_text(splitter, text)
    def split_document(splitter, document), do: Shared.split_document(splitter, document)
  end
end

defmodule BeamWeaver.TextSplitter.Token do
  @moduledoc false
  alias BeamWeaver.TextSplitter.Shared

  defstruct Shared.common_fields() ++ [tokenizer: %BeamWeaver.Tokenizer.Approximate{}]

  def new(opts), do: struct(__MODULE__, Shared.normalize_opts(opts))
  def split_text(%__MODULE__{} = splitter, text), do: Shared.token_split_text(splitter, text)
  def split_document(splitter, document), do: Shared.split_document(splitter, document)
end
