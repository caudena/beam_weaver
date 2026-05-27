defmodule BeamWeaver.Agent.Middleware.PII do
  @moduledoc """
  Detects and edits common PII in agent message text.

  The middleware keeps BeamWeaver's native middleware shape while matching the
  LangChain PII semantics: each rule can target user input, model output, tool
  results, or any combination of those boundaries.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.PII.Detector
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Overwrite

  @default_detectors [:email, :credit_card, :ip, :mac_address, :url]
  @strategies [:block, :redact, :mask, :hash]

  defstruct pii_type: nil,
            detectors: @default_detectors,
            detector: nil,
            strategy: :redact,
            replacement: nil,
            custom: [],
            apply_to_input: true,
            apply_to_output: false,
            apply_to_tool_results: false

  def new(opts \\ []) do
    opts =
      case opts do
        type when is_atom(type) or is_binary(type) -> [type: type]
        opts when is_list(opts) -> opts
      end

    pii_type = Keyword.get(opts, :type, Keyword.get(opts, :pii_type))
    detector = Keyword.get(opts, :detector)

    detectors =
      Keyword.get(opts, :detectors, if(pii_type, do: [pii_type], else: @default_detectors))

    strategy = Keyword.get(opts, :strategy, :redact) |> normalize_strategy!()

    Detector.validate_detector_config!(pii_type, detector, detectors)

    %__MODULE__{
      pii_type: Detector.normalize_type(pii_type),
      detectors: Enum.map(List.wrap(detectors), &Detector.normalize_detector/1),
      detector: detector,
      strategy: strategy,
      replacement: Keyword.get(opts, :replacement),
      custom: Keyword.get(opts, :custom, []),
      apply_to_input: Keyword.get(opts, :apply_to_input, true),
      apply_to_output: Keyword.get(opts, :apply_to_output, false),
      apply_to_tool_results: Keyword.get(opts, :apply_to_tool_results, false)
    }
  end

  @impl true
  def name(%__MODULE__{pii_type: nil, detectors: detectors}),
    do: "pii[#{Enum.map_join(detectors, ",", &Detector.detector_type/1)}]"

  def name(%__MODULE__{pii_type: pii_type}), do: "pii[#{pii_type}]"

  @impl true
  def can_jump_to(_middleware, hook) when hook in [:before_model, :after_model], do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def before_model(
        %__MODULE__{apply_to_input: false, apply_to_tool_results: false},
        _state,
        _runtime
      ),
      do: nil

  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = State.messages(state)

    messages
    |> edit_before_model(middleware)
    |> format_update(messages)
  end

  def after_model(%__MODULE__{apply_to_output: false}, _state, _runtime), do: nil

  def after_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = State.messages(state)

    messages
    |> edit_last_message(:assistant, middleware)
    |> format_update(messages)
  end

  @doc """
  Detects email addresses and returns match maps with byte offsets.
  """
  defdelegate detect_email(content), to: Detector

  @doc """
  Detects Luhn-valid credit-card numbers in common 16-digit formats.
  """
  defdelegate detect_credit_card(content), to: Detector

  @doc """
  Detects valid IPv4 addresses.
  """
  defdelegate detect_ip(content), to: Detector

  @doc """
  Detects colon- or dash-separated MAC addresses.
  """
  defdelegate detect_mac_address(content), to: Detector

  @doc """
  Detects http/https URLs, www-hosts, and bare domains with paths.
  """
  defdelegate detect_url(content), to: Detector

  @doc """
  Applies a redaction strategy to previously detected PII matches.
  """
  def apply_strategy(content, [], _strategy), do: content

  def apply_strategy(content, matches, strategy) when is_binary(content) and is_list(matches) do
    case normalize_strategy!(strategy) do
      :redact -> replace_matches(content, matches, &redacted_placeholder/1)
      :mask -> replace_matches(content, matches, &mask/1)
      :hash -> replace_matches(content, matches, &hash/1)
      :block -> raise ArgumentError, "PII block strategy must be handled at middleware boundary"
    end
  end

  defp edit_before_model(messages, middleware) do
    with {:ok, messages, changed?} <-
           maybe_edit_last_input(messages, middleware, middleware.apply_to_input),
         {:ok, messages, tool_changed?} <-
           maybe_edit_tool_results(messages, middleware, middleware.apply_to_tool_results) do
      {:ok, messages, changed? or tool_changed?}
    end
  end

  defp maybe_edit_last_input(messages, _middleware, false), do: {:ok, messages, false}

  defp maybe_edit_last_input(messages, middleware, true),
    do: edit_last_message(messages, :user, middleware)

  defp maybe_edit_tool_results(messages, _middleware, false), do: {:ok, messages, false}

  defp maybe_edit_tool_results(messages, middleware, true) do
    case last_role_index(messages, :assistant) do
      nil ->
        {:ok, messages, false}

      last_ai_idx ->
        edit_messages_after(messages, last_ai_idx, middleware, false)
    end
  end

  defp edit_messages_after(messages, index, _middleware, changed?)
       when index >= length(messages) - 1,
       do: {:ok, messages, changed?}

  defp edit_messages_after(messages, index, middleware, changed?) do
    next_index = index + 1

    case Enum.at(messages, next_index) do
      %Message{role: :tool, content: content} = message when is_binary(content) ->
        case edit_text(content, middleware) do
          {:ok, ^content} ->
            edit_messages_after(messages, next_index, middleware, changed?)

          {:ok, edited} ->
            messages
            |> List.replace_at(next_index, %{message | content: edited})
            |> edit_messages_after(next_index, middleware, true)

          {:error, %Error{} = error} ->
            {:error, error}
        end

      _other ->
        edit_messages_after(messages, next_index, middleware, changed?)
    end
  end

  defp edit_last_message(messages, role, middleware) do
    case last_role_index(messages, role) do
      nil ->
        {:ok, messages, false}

      index ->
        case Enum.at(messages, index) do
          %Message{content: content} = message when is_binary(content) and content != "" ->
            case edit_text(content, middleware) do
              {:ok, ^content} ->
                {:ok, messages, false}

              {:ok, edited} ->
                {:ok, List.replace_at(messages, index, %{message | content: edited}), true}

              {:error, %Error{} = error} ->
                {:error, error}
            end

          _message ->
            {:ok, messages, false}
        end
    end
  end

  defp format_update({:ok, _messages, false}, _original), do: nil
  defp format_update({:ok, messages, true}, _original), do: %{messages: Overwrite.new(messages)}
  defp format_update({:error, %Error{} = error}, _original), do: {:error, error}

  defp edit_text(text, %__MODULE__{} = middleware) do
    matches = Detector.detect(text, middleware)

    if matches == [] do
      {:ok, text}
    else
      case middleware.strategy do
        :block ->
          {:error, pii_error(matches)}

        :redact ->
          {:ok, replace_matches(text, matches, &redact(&1, middleware))}

        :mask ->
          {:ok, replace_matches(text, matches, &mask/1)}

        :hash ->
          {:ok, replace_matches(text, matches, &hash/1)}
      end
    end
  end

  defp replace_matches(text, matches, fun) do
    matches
    |> Enum.map(&Detector.normalize_match(&1, nil))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.start, :desc)
    |> Enum.reduce(text, fn match, acc ->
      binary_part(acc, 0, match.start) <>
        fun.(match) <> binary_part(acc, match.end, byte_size(acc) - match.end)
    end)
  end

  defp redact(_match, %__MODULE__{replacement: replacement}) when is_binary(replacement),
    do: replacement

  defp redact(match, _middleware), do: redacted_placeholder(match)

  defp redacted_placeholder(match), do: "[REDACTED_#{String.upcase(match.type)}]"

  defp mask(%{type: "email", value: value}) do
    case String.split(value, "@", parts: 2) do
      [user, domain] ->
        case String.split(domain, ".") do
          [_single] -> user <> "@****"
          parts -> user <> "@****." <> List.last(parts)
        end

      _other ->
        "****"
    end
  end

  defp mask(%{type: "credit_card", value: value}) do
    digits = String.replace(value, ~r/\D/, "")
    suffix = String.slice(digits, -4, 4)

    cond do
      String.contains?(value, "-") -> "****-****-****-" <> suffix
      String.contains?(value, " ") -> "**** **** **** " <> suffix
      true -> "************" <> suffix
    end
  end

  defp mask(%{type: "ip", value: value}) do
    case String.split(value, ".") do
      [_, _, _, last] -> "*.*.*." <> last
      _other -> "****"
    end
  end

  defp mask(%{type: "mac_address", value: value}) do
    separator = if String.contains?(value, ":"), do: ":", else: "-"

    "**#{separator}**#{separator}**#{separator}**#{separator}**#{separator}" <>
      String.slice(value, -2, 2)
  end

  defp mask(%{type: "url"}), do: "[MASKED_URL]"

  defp mask(%{value: value}) when byte_size(value) <= 4, do: "****"

  defp mask(%{value: value}) do
    suffix = binary_part(value, byte_size(value) - 4, 4)
    "****" <> suffix
  end

  defp hash(%{type: type, value: value}) do
    digest =
      :crypto.hash(:sha256, value)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "<#{type}_hash:#{digest}>"
  end

  defp last_role_index(messages, role) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: ^role}, index} -> index
      _other -> nil
    end)
  end

  defp pii_error([first | _] = matches) do
    Error.new(
      :pii_detected,
      "Detected #{length(matches)} instance(s) of #{first.type} in text content",
      %{pii_type: first.type, matches: matches}
    )
  end

  defp normalize_strategy!(strategy) when strategy in @strategies, do: strategy

  defp normalize_strategy!(strategy) when is_binary(strategy) do
    case strategy do
      "block" -> :block
      "redact" -> :redact
      "mask" -> :mask
      "hash" -> :hash
      _other -> raise ArgumentError, "unknown PII strategy: #{strategy}"
    end
  end

  defp normalize_strategy!(strategy),
    do: raise(ArgumentError, "unknown PII strategy: #{inspect(strategy)}")
end
