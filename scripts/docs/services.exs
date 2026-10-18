defmodule BeamWeaver.Docs.Services do
  @moduledoc false

  # Each database scenario owns its container. Never falls back to the user's
  # local database or their DATABASE_URL.
  def with_services(requirements, fun) do
    if "postgres" in requirements do
      with_postgres(fun)
    else
      fun.([])
    end
  end

  defp with_postgres(fun) do
    name = "beam-weaver-docs-#{System.unique_integer([:positive])}-#{System.pid()}"

    case System.cmd(
           "docker",
           [
             "run",
             "--detach",
             "--rm",
             "--name",
             name,
             "-e",
             "POSTGRES_PASSWORD=docs-test",
             "-e",
             "POSTGRES_DB=docs",
             "-p",
             "127.0.0.1::5432",
             "pgvector/pgvector:pg17"
           ],
           stderr_to_stdout: true
         ) do
      {_id, 0} ->
        try do
          wait_postgres(name, 60)
          {port, 0} = System.cmd("docker", ["port", name, "5432/tcp"])
          port = port |> String.trim() |> String.split(":") |> List.last()
          fun.([{"DATABASE_URL", "ecto://postgres:docs-test@127.0.0.1:#{port}/docs"}])
        after
          System.cmd("docker", ["rm", "--force", name], stderr_to_stdout: true)
        end

      {output, _} ->
        {:blocked, "Cannot start disposable PostgreSQL: #{String.slice(output, 0, 500)}"}
    end
  rescue
    error -> {:blocked, Exception.message(error)}
  end

  defp wait_postgres(_name, 0), do: raise("PostgreSQL did not become ready")

  defp wait_postgres(name, remaining) do
    case System.cmd("docker", ["exec", name, "pg_isready", "-U", "postgres", "-d", "docs"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        Process.sleep(500)
        wait_postgres(name, remaining - 1)
    end
  end
end
