defmodule BeamWeaver.TestSupport.OpenAIDecisions do
  # An OpenAI decision model whose requests the test answers, by default with
  # the first choice, the lowest level and a 0.2 probability.

  alias BeamWeaver.Transport.Response

  defmodule Transport do
    @behaviour BeamWeaver.Transport

    def request(request, opts) do
      if parent = opts[:parent], do: send(parent, {:decisions_request, request})

      case opts[:respond] do
        fun when is_function(fun, 1) -> fun.(request)
        _default -> {:ok, BeamWeaver.TestSupport.OpenAIDecisions.response(request.json["questions"], opts)}
      end
    end
  end

  def model(opts \\ []) do
    BeamWeaver.Models.init_decision_model!("openai:gpt-6-luna",
      api_key: "fixture-secret",
      transport: Transport,
      transport_opts: Keyword.put_new(opts, :parent, self())
    )
  end

  def response(questions, opts \\ []),
    do: Response.new(status: 200, body: body(questions, opts), headers: [{"x-request-id", "req_fixture"}])

  def body(questions, opts \\ []) do
    %{
      "model" => "gpt-6-luna",
      "answers" => Enum.map(questions, &answer(&1, opts)),
      "usage" => %{"input_tokens" => 100, "output_tokens" => 0, "total_tokens" => 100}
    }
  end

  defp answer(%{"name" => name} = question, opts) do
    if opts[:refuse], do: %{"type" => "refusal", "name" => name}, else: answer_for(question, opts)
  end

  defp answer_for(%{"type" => "predicate", "name" => name}, opts),
    do: %{"type" => "predicate", "name" => name, "probability" => Keyword.get(opts, :probability, 0.2)}

  defp answer_for(%{"type" => "choice", "name" => name, "choices" => choices}, opts) do
    values = Enum.map(choices, & &1["value"])
    choice = Keyword.get(opts, :choice, hd(values))

    %{
      "type" => "choice",
      "name" => name,
      "choice" => choice,
      "confidence" => Keyword.get(opts, :confidence, 0.9),
      "probabilities" => Enum.map(values, &%{"value" => &1, "probability" => if(&1 == choice, do: 1.0, else: 0.0)})
    }
  end

  defp answer_for(%{"type" => "score", "name" => name, "levels" => levels}, _opts) do
    %{
      "type" => "score",
      "name" => name,
      "score" => 0.0,
      "confidence" => 1.0,
      "probabilities" =>
        levels
        |> Enum.with_index()
        |> Enum.map(fn {level, index} ->
          %{"value" => index, "label" => level["label"], "probability" => if(index == 0, do: 1.0, else: 0.0)}
        end)
    }
  end
end
