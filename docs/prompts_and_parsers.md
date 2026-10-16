# Prompts and Parsers

A prompt template turns your data into the text or messages you send to a
model, and an output parser turns the model's reply back into data. Use them
when you call a model yourself, in a function or a graph node; an agent builds
its prompt from its `system_prompt` and the conversation.

```elixir
alias BeamWeaver.{OutputParser, Prompt}

prompt = Prompt.string("Classify this ticket as billing, shipping or other, in JSON: {ticket}")
{:ok, text} = Prompt.format(prompt, %{ticket: "I was charged twice for order A-1001."})

# Send `text` to a model. It replies:
reply = ~s({"category": "billing"})

OutputParser.parse(OutputParser.json(), reply)
#=> {:ok, %{"category" => "billing"}}
```

## Templates

`{name}` marks a variable. `BeamWeaver.Prompt.format/3` fills the variables
from a map with atom or string keys and returns `{:ok, text}`. A missing
variable is an error, not an empty string:

```elixir
Prompt.format(prompt, %{})
#=> {:error, %BeamWeaver.Core.Error{type: :prompt_missing_variable, details: %{variable: "ticket"}}}
```

`Prompt.variables/1` lists the variables a prompt needs. A dotted name such as
`{customer.name}` reads a nested map or struct, and `{{` and `}}` write a
literal brace, for a JSON example inside a prompt (a variable can't sit inside
escaped braces). The option `template_format: :mustache` switches to
`{{name}}` variables; there, a missing variable renders as an empty string.

## Chat prompts

`BeamWeaver.Prompt.chat/2` builds a list of messages, one per
`{role, template}`:

```elixir
alias BeamWeaver.Core.Message

chat =
  Prompt.chat([
    {:system, "You are Acme's support agent. Answer in a {tone} tone."},
    Prompt.placeholder("history", optional: true),
    {:user, "{question}"}
  ])

{:ok, value} =
  Prompt.format_prompt(chat, %{
    tone: "friendly",
    history: [Message.user("Where is order A-1001?"), Message.assistant("It shipped on Monday.")],
    question: "When will it arrive?"
  })

value |> Prompt.to_messages() |> Enum.map(& &1.role)
#=> [:system, :user, :assistant, :user]
```

`Prompt.placeholder/2` inserts a list of messages, such as the conversation so
far: `optional: true` lets you leave it out, and `max_length:` keeps only the
newest messages. `Prompt.format_prompt/3` returns a `BeamWeaver.Prompt.Value`,
and `Prompt.to_messages/1` turns it into the message list a chat model takes.

A role is `:system`, `:user`, `:assistant` or `:tool`, or the same as a
string. `"developer"` becomes a system message, as in
`BeamWeaver.Core.Message.from/1`; any other role is an error when the prompt
is formatted or saved:

```elixir
Prompt.format(Prompt.chat([{"human", "{question}"}]), %{question: "When will it arrive?"})
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_role, details: %{role: "human"}}}
```

## Partials

`BeamWeaver.Prompt.partial/2` fills some variables ahead of time, so callers
pass only the rest:

```elixir
short = Prompt.partial(chat, %{tone: "short"})
Prompt.variables(short)
#=> ["question"]
```

A partial can be a function, called each time the prompt is formatted, such as
`fn -> Date.to_iso8601(Date.utc_today()) end` for today's date. A value you
pass to `format/3` overrides the partial of the same name, with an atom or a
string key:

```elixir
{:ok, value} = Prompt.format_prompt(short, %{"tone" => "formal", question: "When will it arrive?"})
value |> Prompt.to_messages() |> hd() |> Message.text()
#=> "You are Acme's support agent. Answer in a formal tone."
```

## Output parsers

An output parser reads a model's reply, a string or an assistant message. It
returns `{:ok, data}`, or an `:output_parser_error` when the reply doesn't
fit, so you can retry or fall back.

| `BeamWeaver.OutputParser` | Returns |
| --- | --- |
| `json/1` | The decoded JSON, also when the model wraps it in a Markdown code fence or puts a sentence before it. `partial: true` accepts unfinished JSON. |
| `schema/2` | The decoded JSON, checked against a JSON Schema or a schema module: required keys, types and enums |
| `xml/1` | A map with the element's `name`, `text` and `children`, and `attributes` when it has any |
| `list/1`, `markdown_list/1`, `numbered_list/1` | A list of strings |
| `csv/1` | A list of rows |

```elixir
xml = "<ticket><category>billing</category><priority>low</priority></ticket>"

OutputParser.parse(OutputParser.xml(), xml)
#=> {:ok, %{name: "ticket", children: [%{name: "category", text: "billing"}, %{name: "priority", text: "low"}]}}
```

`OutputParser.schema/2` takes a JSON Schema map or a `BeamWeaver.Schema`
module:

```elixir
defmodule MyApp.Schemas.Triage do
  use BeamWeaver.Schema

  field :category, :string, enum: ["shipping", "billing", "other"]
  field :priority, :string, enum: ["low", "high"]
end

parser = OutputParser.schema(MyApp.Schemas.Triage)

OutputParser.parse(parser, ~s({"category": "toys", "priority": "high"}))
#=> {:error, %BeamWeaver.Core.Error{type: :output_parser_error, message: "parsed output field is not in enum"}}
```

## Few-shot prompts

A few examples in the prompt show a model the format or the labels you want
better than a description does. `BeamWeaver.Prompt.few_shot/1` renders
examples between a prefix and a suffix:

```elixir
examples = [
  %{ticket: "I was charged twice for order A-1001.", category: "billing"},
  %{ticket: "My parcel has not arrived yet.", category: "shipping"},
  %{ticket: "How do I change my password?", category: "other"}
]

few_shot =
  Prompt.few_shot(
    examples: examples,
    example_prompt: Prompt.string("Ticket: {ticket}\nCategory: {category}"),
    prefix: "Classify each support ticket.",
    suffix: "Ticket: {ticket}\nCategory:"
  )

{:ok, text} = Prompt.format(few_shot, %{ticket: "Where is order A-1002?"})
String.split(text, "\n\n")
#=> ["Classify each support ticket.",
#    "Ticket: I was charged twice for order A-1001.\nCategory: billing",
#    "Ticket: My parcel has not arrived yet.\nCategory: shipping",
#    "Ticket: How do I change my password?\nCategory: other",
#    "Ticket: Where is order A-1002?\nCategory:"]
```

`Prompt.few_shot_chat/1` does the same for chat models, with each example as
a user and an assistant message:
`example_prompt: Prompt.chat([{:user, "{ticket}"}, {:assistant, "{category}"}])`.
Instead of `prefix:` and `suffix:`, it takes lists of messages,
`prefix_messages:` and `suffix_messages:`. Both builders raise an
`ArgumentError` for an option they don't take.

With many examples, show only the ones that suit the input. An example
selector picks them each time the prompt is formatted; pass it to `few_shot/1`
as `example_selector:` instead of `examples:`. (With the fake embedding model,
its picks are arbitrary.)

```elixir
alias BeamWeaver.ExampleSelector

embeddings = BeamWeaver.Models.init_embeddings!("fake:embedding")
{:ok, similar} = ExampleSelector.semantic_similarity(examples, embeddings, k: 2, input_keys: [:ticket])

ExampleSelector.select(similar, %{ticket: "Where is order A-1002?"})
#=> {:ok, [%{ticket: _, category: _}, %{ticket: _, category: _}]}
```

| `BeamWeaver.ExampleSelector` | Picks |
| --- | --- |
| `semantic_similarity/3` | The `k:` examples closest in meaning to the input, compared on `input_keys:` |
| `max_marginal_relevance/3` | Examples close to the input that also differ from each other |
| `length_based/2` | As many examples as fit in `max_length:` words, the input included |
| `metadata_filter/2` | The examples of another selector that a function accepts |

## Prompt, model and parser

Chain the three steps with `with`. Each returns `{:ok, value}` or
`{:error, error}`, so the chain stops at the first failure:

```elixir
defmodule MyApp.TicketClassifier do
  alias BeamWeaver.{OutputParser, Prompt}
  alias BeamWeaver.Core.ChatModel

  def classify(model, ticket) do
    parser = OutputParser.schema(MyApp.Schemas.Triage)

    prompt =
      Prompt.chat([
        {:system, "Classify the support ticket. {format_instructions}"},
        {:user, "{ticket}"}
      ])

    input = %{ticket: ticket, format_instructions: OutputParser.get_format_instructions(parser)}

    with {:ok, value} <- Prompt.format_prompt(prompt, input),
         {:ok, reply} <- ChatModel.invoke(model, Prompt.to_messages(value)) do
      OutputParser.parse(parser, reply)
    end
  end
end

model =
  BeamWeaver.Models.init_chat_model!("fake:chat",
    responses: [~s({"category": "shipping", "priority": "high"})]
  )

MyApp.TicketClassifier.classify(model, "My order A-1001 never arrived!")
#=> {:ok, %{"category" => "shipping", "priority" => "high"}}
```

`OutputParser.get_format_instructions/1` describes the expected format,
schema included. Pass it as a variable, as here: in the template text, its
braces would read as variables. Agents don't need any of this: an agent with a
`response_schema` gets typed answers ([Structured Output](structured_output.md)).

`BeamWeaver.Runnable.sequence/2` joins the same steps into one value that you
can pass around and run with `Runnable.invoke/3` or `Runnable.batch/3`. Each
step gets the previous step's result, and a chat model takes the formatted
prompt as its messages:

```elixir
alias BeamWeaver.Runnable

triage =
  Runnable.sequence([
    Prompt.chat([{:system, "Classify the support ticket as JSON."}, {:user, "{ticket}"}]),
    BeamWeaver.Models.init_chat_model!("fake:chat", responses: [~s({"category": "billing", "priority": "low"})]),
    OutputParser.schema(MyApp.Schemas.Triage)
  ])

Runnable.invoke(triage, %{ticket: "I was charged twice for order A-1001."})
#=> {:ok, %{"category" => "billing", "priority" => "low"}}
```

## Prompts in files

<!-- snippet: compile -->
```elixir
{:ok, answer} = Prompt.from_file("priv/prompts/answer.txt")
:ok = Prompt.save(chat, "priv/prompts/support.yaml")
{:ok, chat} = Prompt.load("priv/prompts/support.yaml")
```

`Prompt.from_file/2` reads a plain text template. `Prompt.save/3` writes a
prompt and its partials as YAML or JSON, by the file's extension, and
`Prompt.load/2` reads it back. Messages you put in a chat prompt as they are,
such as `Message.system("...")`, are saved as messages, not templates, so their
braces stay text. A prompt with a function partial or an example selector
can't be saved.

## Reference

- [`BeamWeaver.Prompt`](https://hexdocs.pm/beam_weaver/BeamWeaver.Prompt.html): templates, chat prompts, partials, few-shot prompts and prompt files
- [`BeamWeaver.Prompt.Value`](https://hexdocs.pm/beam_weaver/BeamWeaver.Prompt.Value.html): a formatted prompt, as text or messages
- [`BeamWeaver.OutputParser`](https://hexdocs.pm/beam_weaver/BeamWeaver.OutputParser.html): parsing replies into data
- [`BeamWeaver.ExampleSelector`](https://hexdocs.pm/beam_weaver/BeamWeaver.ExampleSelector.html): choosing few-shot examples
- [`BeamWeaver.Runnable`](https://hexdocs.pm/beam_weaver/BeamWeaver.Runnable.html): running prompts, models and parsers as steps of a sequence
- [`BeamWeaver.Core.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ChatModel.html): calling a chat model directly
- [`BeamWeaver.Schema`](https://hexdocs.pm/beam_weaver/BeamWeaver.Schema.html): schema modules
