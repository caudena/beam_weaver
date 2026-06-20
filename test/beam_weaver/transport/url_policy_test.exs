defmodule BeamWeaver.Transport.URLPolicyTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Transport.URLPolicy

  test "allows public HTTP when explicitly configured and keeps HTTPS-only default" do
    assert {:error, %Error{type: :unsafe_url}} = URLPolicy.validate("http://example.com/hook")

    assert {:ok, "http://example.com/hook"} =
             URLPolicy.validate("http://example.com/hook", schemes: ["http", "https"])

    assert {:ok, "https://example.com/hook"} = URLPolicy.validate("https://example.com/hook")
  end

  test "blocks localhost, docker, kubernetes, metadata, and userinfo hosts by default" do
    for url <- [
          "https://user:pass@example.com",
          "https://localhost:8080",
          "https://host.docker.internal:8080",
          "https://api.default.svc.cluster.local",
          "https://metadata.google.internal/computeMetadata/v1",
          "https://169.254.169.254/latest/meta-data/"
        ] do
      assert {:error, %Error{type: :unsafe_url}} = URLPolicy.validate(url)
    end
  end

  test "explicit allowed hosts bypass hostname and DNS category checks" do
    assert {:ok, "https://metadata.google.internal/path"} =
             URLPolicy.validate("https://metadata.google.internal/path",
               allowed_hosts: ["metadata.google.internal"]
             )

    assert {:error, %Error{type: :unsafe_url}} =
             URLPolicy.validate("https://other.example/path",
               allowed_hosts: ["metadata.google.internal"]
             )
  end

  test "blocks private, loopback, metadata, mapped IPv4, NAT64, and reserved IP literals" do
    for url <- [
          "https://10.0.0.1",
          "https://100.64.0.1",
          "https://172.16.0.1",
          "https://192.168.1.1",
          "https://127.0.0.1",
          "https://169.254.170.23",
          "https://100.100.100.200",
          "https://[::1]",
          "https://[::ffff:127.0.0.1]",
          "https://[64:ff9b::c0a8:0101]",
          "https://[fe80::a9fe:a9fe]",
          "https://192.0.2.1"
        ] do
      assert {:error, %Error{type: :unsafe_url}} = URLPolicy.validate(url)
    end
  end

  test "private RFC1918 literals require opt-in and metadata remains separately guarded" do
    assert {:ok, "https://10.0.0.1"} =
             URLPolicy.validate("https://10.0.0.1", allow_private?: true)

    assert {:error, %Error{type: :unsafe_url}} =
             URLPolicy.validate("https://127.0.0.1", allow_private?: true)

    assert {:ok, "https://127.0.0.1"} =
             URLPolicy.validate("https://127.0.0.1",
               allow_private?: true,
               allow_localhost?: true
             )

    assert {:error, %Error{type: :unsafe_url}} =
             URLPolicy.validate("https://169.254.169.254", allow_private?: true)

    for url <- ["https://[fd00:ec2::254]", "https://[fd00:ec2::23]"] do
      assert {:error, %Error{type: :unsafe_url}} =
               URLPolicy.validate(url, allow_private?: true)
    end
  end

  test "DNS resolution can fail closed before transport calls" do
    resolver = fn
      "public.example", 443 -> {:ok, [{93, 184, 216, 34}]}
      "private.example", 443 -> {:ok, [{127, 0, 0, 1}]}
      "missing.example", 443 -> {:error, :nxdomain}
    end

    assert {:ok, "https://public.example/path"} =
             URLPolicy.validate("https://public.example/path",
               resolve?: true,
               resolver: resolver
             )

    assert {:error, %Error{type: :unsafe_url, message: "DNS resolution produced a blocked address"}} =
             URLPolicy.validate("https://private.example/path",
               resolve?: true,
               resolver: resolver
             )

    assert {:error, %Error{type: :unsafe_url, message: "DNS resolution failed"}} =
             URLPolicy.validate("https://missing.example/path",
               resolve?: true,
               resolver: resolver
             )
  end

  test "reserved IPv4 ranges only block their precise CIDRs, not whole /16 blocks" do
    for url <- [
          "https://192.0.2.1",
          "https://198.18.0.1",
          "https://198.19.255.1",
          "https://198.51.100.1",
          "https://203.0.113.1"
        ] do
      assert {:error, %Error{type: :unsafe_url}} = URLPolicy.validate(url)
    end

    for url <- [
          "https://192.2.0.1",
          "https://198.51.99.1",
          "https://198.51.101.1",
          "https://203.0.112.1",
          "https://203.0.114.1"
        ] do
      assert {:ok, ^url} = URLPolicy.validate(url)
    end
  end

  test "IPv6 link-local fe80::/10 stays blocked even when metadata is allowed" do
    assert {:error, %Error{type: :unsafe_url}} =
             URLPolicy.validate("https://[fe80::a9fe:a9fe]", allow_metadata?: true)

    assert {:ok, "https://169.254.169.254/latest/meta-data/"} =
             URLPolicy.validate("https://169.254.169.254/latest/meta-data/", allow_metadata?: true)
  end

  test "safe? exposes non-raising validation result" do
    assert URLPolicy.safe?("https://example.com/hook")
    refute URLPolicy.safe?("https://127.0.0.1/hook")

    assert URLPolicy.safe?("http://example.com/hook", schemes: ["http", "https"])
  end
end
