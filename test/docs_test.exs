# One test module per documentation page, so pages run concurrently. Run a
# single page with `mix test test/docs_test.exs --only doc_page:<slug>`, where
# the slug is the path under docs/ with "/" replaced by "_" (root README.md is
# `root_readme`).
alias BeamWeaver.TestSupport.DocSnippets

for page <- DocSnippets.pages() do
  # A page that defines ExUnit test modules runs now, while this file loads,
  # because ExUnit runs only the test modules defined before every test file
  # has loaded. Its test reports the result; its test modules run with the suite.
  check =
    if DocSnippets.defines_test_modules?(page) do
      case DocSnippets.check_page(page) do
        :ok -> :ok
        {:error, message} -> quote(do: flunk(unquote(message)))
      end
    else
      quote(do: DocSnippets.run_page!(unquote(Macro.escape(page))))
    end

  contents =
    quote do
      use ExUnit.Case, async: unquote(DocSnippets.async?(page))

      @moduletag doc_page: unquote(DocSnippets.slug(page))

      test unquote("code examples in #{inspect(page)}") do
        unquote(check)
      end
    end

  Module.create(Module.concat(BeamWeaver.DocsTest, DocSnippets.module_suffix(page)), contents, __ENV__)
end
