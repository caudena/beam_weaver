defmodule BeamWeaver.Transport.URLPolicy do
  @moduledoc """
  SSRF-oriented URL validation for loaders and transport boundaries.

  This is intentionally conservative and local. It validates URL shape and
  literal IP/localhost targets by default. Callers that are about to perform a
  network request can enable DNS resolution with an injected resolver so the
  same policy can fail closed before transport I/O. `allowed_hosts` narrows the
  accepted host set; it never bypasses private, metadata, or reserved-address
  checks. With `pin_resolved?: true`, `Transport.Safe` connects to one validated
  address while retaining the original Host and TLS hostname.
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
            pin_resolved?: false,
            follow_redirects?: false,
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
      pin_resolved?: Keyword.get(opts, :pin_resolved?, false),
      follow_redirects?: Keyword.get(opts, :follow_redirects?, false),
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

    cond do
      is_nil(scheme) or is_nil(host) ->
        unsafe(url, "URL must include scheme and host")

      uri.userinfo not in [nil, ""] ->
        unsafe(url, "URL userinfo is not allowed")

      uri.fragment not in [nil, ""] ->
        unsafe(url, "URL fragments are not allowed")

      not valid_port?(uri.port) ->
        unsafe(url, "URL port is invalid")

      scheme not in policy.schemes ->
        unsafe(url, "URL scheme is not allowed", %{
          scheme: scheme,
          allowed_schemes: policy.schemes
        })

      blocked_host?(host, policy) ->
        unsafe(url, "URL host is blocked", %{host: host})

      not allowed_host?(host, policy) ->
        unsafe(url, "URL host is not in the allowlist", %{host: host})

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
        validate_resolved(canonical_url(uri, scheme, host), host, uri, policy)

      true ->
        {:ok, canonical_url(uri, scheme, host)}
    end
  end

  def validate(url, _policy),
    do: {:error, Error.new(:unsafe_url, "URL must be a string", %{url: inspect(url)})}

  @spec safe?(String.t(), keyword() | t()) :: boolean()
  def safe?(url, policy \\ %__MODULE__{}) do
    match?({:ok, _url}, validate(url, policy))
  end

  @doc false
  def resolve_target(url, policy) when is_binary(url) do
    with {:ok, %{targets: [target | _targets]}} <- resolve_targets(url, policy) do
      {:ok, target}
    end
  end

  @doc false
  @spec resolve_targets(String.t(), keyword() | t()) ::
          {:ok, %{targets: [map()], address_set: [tuple()]}} | {:error, Error.t()}
  def resolve_targets(url, policy) when is_binary(url) do
    policy = new(policy)

    with {:ok, canonical_url} <- validate(url, %{policy | resolve?: false}),
         uri <- URI.parse(canonical_url),
         host <- normalize_host(uri.host),
         port <- uri.port || default_port(uri.scheme),
         {:ok, [_address | _rest] = addresses} <- target_addresses(host, port, policy),
         addresses <- addresses |> Enum.uniq() |> Enum.sort(),
         nil <- Enum.find(addresses, &blocked_ip?(&1, policy)) do
      {:ok,
       %{
         address_set: addresses,
         targets:
           Enum.map(addresses, fn address ->
             %{
               url: canonical_url,
               host: host,
               port: port,
               address: address,
               address_set: addresses
             }
           end)
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:ok, []} ->
        unsafe(url, "DNS resolution returned no addresses", %{host: URI.parse(url).host})

      {:error, reason} ->
        unsafe(url, "DNS resolution failed", %{reason: inspect(reason)})

      address when is_tuple(address) ->
        unsafe(url, "DNS resolution produced a blocked address", %{
          host: URI.parse(url).host,
          address: inspect(address)
        })
    end
  end

  defp unsafe(url, reason, details \\ %{}) do
    {:error, Error.new(:unsafe_url, reason, Map.put(details, :url, url))}
  end

  defp normalize_scheme(nil), do: nil
  defp normalize_scheme(scheme), do: scheme |> to_string() |> String.downcase()

  defp normalize_host(nil), do: nil

  defp normalize_host(host) do
    host = host |> to_string() |> String.trim_trailing(".")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        address |> :inet.ntoa() |> List.to_string() |> String.downcase()

      {:error, :einval} ->
        canonical_idna_host(host)
    end
  end

  defp canonical_idna_host(host) do
    labels = Regex.split(~r/[.。．｡]/u, host, trim: false)

    if host == "" or Enum.any?(labels, &(&1 == "")) do
      nil
    else
      host
      |> String.to_charlist()
      |> :idna.encode([:uts46, :std3_rules, :strict])
      |> List.to_string()
      |> String.downcase()
      |> case do
        ascii when byte_size(ascii) <= 253 -> ascii
        _too_long -> nil
      end
    end
  catch
    _kind, _reason -> nil
  end

  defp canonical_url(uri, scheme, host) do
    uri
    |> Map.put(:scheme, scheme)
    |> Map.put(:host, host)
    |> Map.put(:authority, nil)
    |> URI.to_string()
  end

  defp valid_port?(nil), do: true
  defp valid_port?(port), do: is_integer(port) and port in 1..65_535

  defp normalize_list(value), do: value |> List.wrap() |> Enum.map(&normalize_scheme/1)
  defp maybe_hosts(nil), do: nil
  defp maybe_hosts(hosts), do: normalize_hosts(hosts)
  defp normalize_hosts(hosts), do: hosts |> List.wrap() |> Enum.map(&normalize_host/1)
  defp blocked_host?(host, policy), do: host in policy.blocked_hosts
  defp allowed_host?(_host, %{allowed_hosts: nil}), do: true
  defp allowed_host?(host, %{allowed_hosts: hosts}), do: host in hosts

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

  defp target_addresses(host, port, policy) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, [address]}
      {:error, :einval} -> resolve_host(host, port, policy)
    end
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

  defp normalize_address(address) when is_tuple(address) and tuple_size(address) in [4, 8] do
    case :inet.ntoa(address) do
      encoded when is_list(encoded) -> {:ok, address}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp ip_scope({0, 0, 0, 0, 0, 0, 0, 0}), do: :reserved

  defp ip_scope({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    ip_scope({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  # The deprecated IPv4-compatible range is not globally routable. Do not
  # treat a public-looking low 32 bits as authority to dial this special range.
  defp ip_scope({0, 0, 0, 0, 0, 0, _high, _low}), do: :reserved

  defp ip_scope({0x64, 0xFF9B, 0, 0, 0, 0, high, low}) do
    ip_scope({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp ip_scope({first, second, third, fourth, _, _, _, _} = address) do
    cond do
      aws_ipv6_metadata?(address) -> :metadata
      nat64_local_use?(first, second, third) -> :reserved
      discard_only?(first, second, third, fourth) -> :reserved
      documentation_ipv6?(first, second) -> :reserved
      (first &&& 0xFE00) == 0xFC00 -> :private
      (first &&& 0xFFC0) == 0xFE80 -> :reserved
      (first &&& 0xFF00) == 0xFF00 -> :reserved
      true -> :public
    end
  end

  # 64:ff9b:1::/48 is reserved for local-use NAT64 translation and is not a
  # public destination. The globally scoped 64:ff9b::/96 is handled above by
  # classifying its embedded IPv4 address.
  defp nat64_local_use?(0x64, 0xFF9B, 1), do: true
  defp nat64_local_use?(_first, _second, _third), do: false

  # 100::/64 is the discard-only prefix.
  defp discard_only?(0x100, 0, 0, 0), do: true
  defp discard_only?(_first, _second, _third, _fourth), do: false

  # RFC 3849 and RFC 9637 documentation ranges are never public destinations.
  defp documentation_ipv6?(0x2001, 0x0DB8), do: true
  defp documentation_ipv6?(0x3FFF, second), do: (second &&& 0xF000) == 0
  defp documentation_ipv6?(_first, _second), do: false

  defp aws_ipv6_metadata?({0xFD00, 0x0EC2, 0, 0, 0, 0, 0, last})
       when last in [0x0023, 0x0254],
       do: true

  defp aws_ipv6_metadata?(_address), do: false

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_int(_value, default), do: default
end
