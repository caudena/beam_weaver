defmodule BeamWeaver.Transport.URLPolicy do
  @moduledoc """
  SSRF-oriented URL validation for loaders and transport boundaries.

  This is intentionally conservative and local. It validates URL shape and
  literal IP/localhost targets by default. Callers that are about to perform a
  network request can enable DNS resolution with an injected resolver so the
  same policy can fail closed before transport I/O.
  """

  import Bitwise

  alias BeamWeaver.Core.Error

  defstruct schemes: ["https"],
            allowed_hosts: nil,
            blocked_hosts: [],
            allow_private?: false,
            allow_localhost?: false,
            allow_metadata?: false,
            allow_kubernetes?: false,
            allow_docker_internal?: false,
            resolve?: false,
            resolver: nil,
            follow_redirects?: true,
            max_redirects: 10,
            max_bytes: 5_000_000,
            timeout: 15_000

  @type t :: %__MODULE__{}

  @spec new(keyword() | t() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = policy), do: policy

  def new(opts) when is_list(opts) do
    %__MODULE__{
      schemes: opts |> Keyword.get(:schemes, ["https"]) |> normalize_list(),
      allowed_hosts: maybe_hosts(Keyword.get(opts, :allowed_hosts)),
      blocked_hosts: opts |> Keyword.get(:blocked_hosts, []) |> normalize_hosts(),
      allow_private?: Keyword.get(opts, :allow_private?, false),
      allow_localhost?: Keyword.get(opts, :allow_localhost?, false),
      allow_metadata?: Keyword.get(opts, :allow_metadata?, false),
      allow_kubernetes?: Keyword.get(opts, :allow_kubernetes?, false),
      allow_docker_internal?: Keyword.get(opts, :allow_docker_internal?, false),
      resolve?: Keyword.get(opts, :resolve?, false),
      resolver: Keyword.get(opts, :resolver),
      follow_redirects?: Keyword.get(opts, :follow_redirects?, true),
      max_redirects: positive_int(Keyword.get(opts, :max_redirects, 10), 10),
      max_bytes: positive_int(Keyword.get(opts, :max_bytes, 5_000_000), 5_000_000),
      timeout: positive_int(Keyword.get(opts, :timeout, 15_000), 15_000)
    }
  end

  @spec validate(String.t(), keyword() | t()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate(url, policy \\ %__MODULE__{})

  def validate(url, policy) when is_binary(url) do
    policy = new(policy)
    uri = URI.parse(url)
    scheme = normalize_scheme(uri.scheme)
    host = normalize_host(uri.host)
    explicitly_allowed? = explicit_allowed_host?(host, policy)

    cond do
      is_nil(scheme) or is_nil(host) ->
        unsafe(url, "URL must include scheme and host")

      uri.userinfo not in [nil, ""] ->
        unsafe(url, "URL userinfo is not allowed")

      scheme not in policy.schemes ->
        unsafe(url, "URL scheme is not allowed", %{
          scheme: scheme,
          allowed_schemes: policy.schemes
        })

      blocked_host?(host, policy) ->
        unsafe(url, "URL host is blocked", %{host: host})

      not allowed_host?(host, policy) ->
        unsafe(url, "URL host is not in the allowlist", %{host: host})

      explicitly_allowed? ->
        {:ok, url}

      docker_internal?(host) and not policy.allow_docker_internal? ->
        unsafe(url, "Docker internal hostnames are not allowed", %{host: host})

      kubernetes_internal?(host) and not policy.allow_kubernetes? ->
        unsafe(url, "Kubernetes internal DNS hostnames are not allowed", %{host: host})

      metadata_host?(host) and not policy.allow_metadata? ->
        unsafe(url, "cloud metadata endpoint URLs are not allowed", %{host: host})

      localhost?(host) and not policy.allow_localhost? ->
        unsafe(url, "localhost URLs are not allowed", %{host: host})

      blocked_literal_ip?(host, policy) ->
        unsafe(url, "private, loopback, metadata, or reserved IP URLs are not allowed", %{
          host: host
        })

      policy.resolve? ->
        validate_resolved(url, host, uri, policy)

      true ->
        {:ok, url}
    end
  end

  def validate(url, _policy),
    do: {:error, Error.new(:unsafe_url, "URL must be a string", %{url: inspect(url)})}

  @spec safe?(String.t(), keyword() | t()) :: boolean()
  def safe?(url, policy \\ %__MODULE__{}) do
    match?({:ok, _url}, validate(url, policy))
  end

  defp unsafe(url, reason, details \\ %{}) do
    {:error, Error.new(:unsafe_url, reason, Map.put(details, :url, url))}
  end

  defp normalize_scheme(nil), do: nil
  defp normalize_scheme(scheme), do: scheme |> to_string() |> String.downcase()

  defp normalize_host(nil), do: nil

  defp normalize_host(host) do
    host
    |> to_string()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp normalize_list(value), do: value |> List.wrap() |> Enum.map(&normalize_scheme/1)
  defp maybe_hosts(nil), do: nil
  defp maybe_hosts(hosts), do: normalize_hosts(hosts)
  defp normalize_hosts(hosts), do: hosts |> List.wrap() |> Enum.map(&normalize_host/1)
  defp blocked_host?(host, policy), do: host in policy.blocked_hosts
  defp allowed_host?(_host, %{allowed_hosts: nil}), do: true
  defp allowed_host?(host, %{allowed_hosts: hosts}), do: host in hosts
  defp explicit_allowed_host?(_host, %{allowed_hosts: nil}), do: false
  defp explicit_allowed_host?(host, %{allowed_hosts: hosts}), do: host in hosts

  defp localhost?(host) do
    host in ["localhost", "localhost.localdomain"] or String.ends_with?(host, ".localhost") or
      String.ends_with?(host, ".local")
  end

  defp docker_internal?(host), do: host in ["host.docker.internal", "gateway.docker.internal"]

  defp kubernetes_internal?(host) do
    host == "kubernetes.default.svc" or String.ends_with?(host, ".svc") or
      String.ends_with?(host, ".svc.cluster.local") or String.ends_with?(host, ".cluster.local")
  end

  defp metadata_host?(host) do
    host in [
      "metadata",
      "metadata.google.internal",
      "metadata.azure.internal",
      "169.254.169.254",
      "100.100.100.200"
    ]
  end

  defp blocked_literal_ip?(host, policy) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> blocked_ip?(address, policy)
      {:error, :einval} -> false
    end
  end

  defp validate_resolved(url, host, uri, policy) do
    port = uri.port || default_port(uri.scheme)

    case resolve_host(host, port, policy) do
      {:ok, []} ->
        unsafe(url, "DNS resolution returned no addresses", %{host: host})

      {:ok, addresses} ->
        case Enum.find(addresses, &blocked_ip?(&1, policy)) do
          nil ->
            {:ok, url}

          address ->
            unsafe(url, "DNS resolution produced a blocked address", %{
              host: host,
              address: inspect(address)
            })
        end

      {:error, reason} ->
        unsafe(url, "DNS resolution failed", %{host: host, reason: inspect(reason)})
    end
  end

  defp resolve_host(host, port, %{resolver: resolver}) when is_function(resolver, 2) do
    resolver.(host, port) |> normalize_resolver_result()
  end

  defp resolve_host(host, _port, %{resolver: resolver}) when is_function(resolver, 1) do
    resolver.(host) |> normalize_resolver_result()
  end

  defp resolve_host(host, _port, _policy) do
    char_host = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(char_host, family) do
          {:ok, resolved} -> resolved
          {:error, _reason} -> []
        end
      end)

    if addresses == [], do: {:error, :nxdomain}, else: {:ok, addresses}
  end

  defp normalize_resolver_result({:ok, addresses}) when is_list(addresses),
    do: normalize_addresses(addresses)

  defp normalize_resolver_result(addresses) when is_list(addresses),
    do: normalize_addresses(addresses)

  defp normalize_resolver_result({:error, reason}), do: {:error, reason}
  defp normalize_resolver_result(other), do: {:error, {:invalid_resolver_result, other}}

  defp normalize_addresses(addresses) do
    addresses
    |> Enum.reduce_while({:ok, []}, fn address, {:ok, acc} ->
      case normalize_address(address) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_address(address) when is_tuple(address) and tuple_size(address) in [4, 8],
    do: {:ok, address}

  defp normalize_address(address) when is_binary(address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_address(address) when is_list(address) do
    address |> List.to_string() |> normalize_address()
  end

  defp normalize_address(address), do: {:error, {:invalid_address, address}}

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
  defp default_port(_scheme), do: 0

  defp blocked_ip?(address, policy) do
    case ip_scope(address) do
      :public -> false
      :private -> not policy.allow_private?
      :loopback -> not policy.allow_localhost?
      :metadata -> not policy.allow_metadata?
      :reserved -> true
    end
  end

  defp ip_scope({a, b, c, d}) do
    cond do
      a == 127 -> :loopback
      a == 169 and b == 254 -> :metadata
      {a, b, c, d} == {100, 100, 100, 200} -> :metadata
      a == 10 -> :private
      a == 100 and b in 64..127 -> :private
      a == 172 and b in 16..31 -> :private
      a == 192 and b == 168 -> :private
      a == 0 -> :reserved
      a == 192 and b == 0 and c in [0, 2] -> :reserved
      a == 198 and b in 18..19 -> :reserved
      a == 198 and b == 51 and c == 100 -> :reserved
      a == 203 and b == 0 and c == 113 -> :reserved
      a >= 224 -> :reserved
      true -> :public
    end
  end

  defp ip_scope({0, 0, 0, 0, 0, 0, 0, 1}), do: :loopback

  defp ip_scope({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    ip_scope({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp ip_scope({0x64, 0xFF9B, 0, 0, 0, 0, high, low}) do
    ip_scope({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp ip_scope({first, _, _, _, _, _, _, _} = address) do
    cond do
      aws_ipv6_metadata?(address) -> :metadata
      (first &&& 0xFE00) == 0xFC00 -> :private
      (first &&& 0xFFC0) == 0xFE80 -> :reserved
      (first &&& 0xFF00) == 0xFF00 -> :reserved
      true -> :public
    end
  end

  defp aws_ipv6_metadata?({0xFD00, 0x0EC2, 0, 0, 0, 0, 0, last})
       when last in [0x0023, 0x0254],
       do: true

  defp aws_ipv6_metadata?(_address), do: false

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end
