# Prompts And Parsers

Prompts and parsers expose focused constructors and tagged results. Internal
composition support is intentionally secondary to direct prompt/parser APIs.

Prompt templates use the safe `:simple` format only, with `{variable}`
interpolation. BeamWeaver does not add Mustache, Jinja2, EEx, or Python
template aliases.

Prompts can be persisted as declarative BeamWeaver specs:

```elixir
prompt =
  BeamWeaver.Prompt.chat([
    BeamWeaver.Prompt.message(:system, "Use {style} answers."),
    BeamWeaver.Prompt.message(:user, "{input}")
  ])
  |> BeamWeaver.Prompt.partial(%{style: "short"})

:ok = BeamWeaver.Prompt.save(prompt, "priv/prompts/support.yaml")
{:ok, loaded} = BeamWeaver.Prompt.load("priv/prompts/support.yaml")
```

The durable format is JSON-compatible BeamWeaver data, not a serialized Elixir
module or Python class reference. Loader configs must declare a BeamWeaver
`"type"` and use native keys such as `"partials"`.

Plain template files can be loaded with `Prompt.from_file/2`:

```elixir
{:ok, prompt} = BeamWeaver.Prompt.from_file("priv/prompts/answer.txt")
```

Output parsers include string, JSON, list, CSV/markdown-list, XML, OpenAI tools,
OpenAI functions, and schema parsers. Failures return tagged
`%BeamWeaver.Core.Error{}` values.

Example:

- `examples/prompt_parser_pipeline.exs`

## Related Guides

- [Messages](messages.md)
- [Models](models.md)
- [Structured Output](structured_output.md)
- [Tools](tools.md)
- [Core](core.md)
