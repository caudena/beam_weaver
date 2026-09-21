defmodule BeamWeaver.TestSupport.TypeSafe do
  alias BeamWeaver.Models
  alias BeamWeaver.TypeSafe.Question

  defmodule Transport do
    @behaviour BeamWeaver.Transport
    def request(request, opts) do
      if parent = opts[:parent], do: send(parent, {:typesafe_request, request})

      case opts[:respond] do
        fun when is_function(fun, 1) ->
          fun.(request)

        _ ->
          {:ok,
           BeamWeaver.Transport.Response.new(
             status: 200,
             body: opts[:body] || BeamWeaver.TestSupport.TypeSafe.body(request.json["questions"]),
             headers: [{"x-typesafe-request-id", "req-fixture"}]
           )}
      end
    end
  end

  def model(opts \\ []) do
    Models.init_decision_model!("typesafe:jev-1.13.0",
      api_key: "fixture-secret",
      transport: Transport,
      transport_opts: Keyword.put_new(opts, :parent, self())
    )
  end

  def input do
    %{
      state: %{ticket: "Customers cannot check out."},
      questions: %{
        route:
          Question.choice(
            instructions: %{question: "Which model?"},
            criteria: %{fast: nil, powerful: %{for: "complex work"}}
          ),
        urgency: Question.noul(instructions: "Is this urgent?", criteria: %{true: ["Customers blocked"], false: nil}),
        severity: Question.score(instructions: nil, criteria: [%{level: "cosmetic"}, ["degraded"], "blocked"])
      }
    }
  end

  def body(questions, choice \\ "powerful", confidence \\ 0.9) do
    answers =
      Map.new(questions, fn {id, q} ->
        answer =
          case q["type"] do
            "noul" ->
              %{"type" => "noul", "noul" => 0.98}

            "choice" ->
              keys = Map.keys(q["criteria"])
              selected = if choice in keys, do: choice, else: hd(keys)

              %{
                "type" => "choice",
                "choice" => selected,
                "confidence" => confidence,
                "probabilities" => Map.new(keys, &{&1, if(&1 == selected, do: 1.0, else: 0.0)})
              }

            "score" ->
              legend = q["criteria"] |> Enum.with_index() |> Map.new(fn {v, i} -> {to_string(i), v} end)

              %{
                "type" => "score",
                "score" => 0.0,
                "confidence" => 1.0,
                "legend" => legend,
                "probabilities" => Map.new(legend, fn {k, _} -> {k, if(k == "0", do: 1.0, else: 0.0)} end)
              }
          end

        {id, answer}
      end)

    %{"model" => "jev-1.13.0", "answers" => answers, "usage" => %{"input_tokens" => 100, "output_tokens" => 20}}
  end
end
