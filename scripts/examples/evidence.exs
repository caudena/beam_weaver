defmodule BeamWeaver.Examples.Evidence do
  @moduledoc false
  alias BeamWeaver.Transport.{Request, Response}
  @transport BeamWeaver.Transport.ReqFinch
  @hosts %{
    "api.openai.com" => :openai,
    "api.anthropic.com" => :anthropic,
    "generativelanguage.googleapis.com" => :google,
    "api.x.ai" => :xai,
    "api.moonshot.ai" => :moonshot,
    "api.z.ai" => :zai,
    "api.deepseek.com" => :deepseek,
    "api.typesafe.ai" => :typesafe
  }

  # Observe the real HTTP implementation without replacing the script's model
  # or transport. A fixture, constructor or unconsumed stream produces no proof.
  # Only public endpoint/model/status fields are retained; never headers or bodies.
  def start do
    Code.ensure_loaded!(@transport)
    collector = spawn_link(fn -> collect(%{}, []) end)
    :erlang.trace_pattern({@transport, :stream_reduce, 4}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(:all, true, [:call, :set_on_spawn, {:tracer, collector}])
    collector
  end

  def finish(collector, required) do
    :erlang.trace(:all, false, [:call, :set_on_spawn])
    ref = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      5_000 -> raise "HTTP evidence delivery timed out"
    end

    :erlang.trace_pattern({@transport, :stream_reduce, 4}, false, [:local])
    send(collector, {:finish, self()})

    records =
      receive do
        {:http_evidence, ^collector, records} -> records
      after
        5_000 -> raise "HTTP evidence collection timed out"
      end

    successful = Enum.filter(records, &(&1.inference and not is_nil(&1.provider) and &1.status in 200..299))
    observed = Enum.map(successful, & &1.provider) |> Enum.uniq()

    %{
      requests: records,
      successful_inference_requests: length(successful),
      required_providers: required,
      observed_providers: observed,
      missing_providers: required -- observed,
      unexpected_providers: observed -- required
    }
  end

  defp collect(pending, records) do
    receive do
      {:trace, pid, :call, {@transport, :stream_reduce, [%Request{} = request | _]}} ->
        uri = URI.parse(request.url)
        body = request.json || %{}
        model = body["model"] || body[:model] || google_model(uri.path || "")

        record = %{
          host: uri.host,
          path: uri.path,
          provider: @hosts[uri.host],
          model: model,
          inference: request.method == :post and inference_path?(uri.path || "")
        }

        collect(Map.update(pending, pid, [record], &[record | &1]), records)

      {:trace, pid, :return_from, {@transport, :stream_reduce, 4}, result} ->
        case Map.get(pending, pid, []) do
          [record | rest] ->
            status =
              case result do
                {:ok, %Response{status: status}, _} -> status
                _ -> nil
              end

            collect(Map.put(pending, pid, rest), [Map.put(record, :status, status) | records])

          [] ->
            collect(pending, records)
        end

      {:finish, caller} ->
        send(caller, {:http_evidence, self(), Enum.reverse(records)})

      _other ->
        collect(pending, records)
    end
  end

  defp google_model(path) do
    case Regex.run(~r{/models/([^/:]+):}, path) do
      [_, model] -> model
      _ -> nil
    end
  end

  defp inference_path?(path),
    do:
      String.ends_with?(path, [
        "/responses",
        "/decisions",
        "/chat/completions",
        "/messages",
        "/systemone",
        "/completions",
        "/embeddings",
        ":generateContent",
        ":streamGenerateContent"
      ])
end
