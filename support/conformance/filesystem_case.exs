defmodule BeamWeaver.TestSupport.Conformance.FilesystemCase do
  @moduledoc """
  Shared ExUnit checks for `BeamWeaver.Filesystem` backends.

  `build:` returns a new, empty backend. A backend whose storage has symlinks
  declares the `:symlinks` capability, and its `build:` returns
  `{backend, make_link}`, where `make_link.(link, target)` makes the backend
  path `link` lead to `target`: permission rules must then see through its
  links (`BeamWeaver.Filesystem.Conformance.check_symlinks/3`). A backend without
  the capability must resolve each path to itself. The `:dir` fixture is the
  folder the checks work in (default `"/"`), such as a `Composite` route.
  """

  import ExUnit.Assertions

  alias BeamWeaver.Filesystem
  alias BeamWeaver.TestSupport.Conformance.Subject

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.TestSupport.Conformance.FilesystemCase
      alias BeamWeaver.TestSupport.Conformance.Subject

      @beamweaver_subject Subject.new(opts, :filesystem)

      if Subject.capability?(@beamweaver_subject, :symlinks) do
        test "permission rules see through the backend's symlinks" do
          FilesystemCase.assert_links_denied(@beamweaver_subject)
        end
      else
        test "a backend without symlinks resolves each path to itself" do
          FilesystemCase.assert_no_links(@beamweaver_subject)
        end
      end
    end
  end

  @doc "Asserts that permission rules see through the subject backend's symlinks."
  def assert_links_denied(%Subject{} = subject) do
    {backend, make_link} =
      case Subject.build(subject) do
        {backend, make_link} when is_function(make_link, 2) -> {backend, make_link}
        other -> flunk("a :symlinks subject's build must return {backend, make_link}, got: #{inspect(other)}")
      end

    case Filesystem.Conformance.check_symlinks(backend, make_link, dir: dir(subject)) do
      :ok ->
        :ok

      {:error, problems} ->
        flunk(
          "permission rules don't see through the backend's symlinks:\n" <>
            Enum.map_join(problems, "\n", &("  * " <> &1))
        )
    end
  end

  @doc "Asserts that the subject backend, which has no symlinks, resolves each path to itself."
  def assert_no_links(%Subject{} = subject) do
    backend =
      case Subject.build(subject) do
        {backend, _make_link} -> backend
        backend -> backend
      end

    dir = dir(subject)
    paths = [Path.join(dir, "secrets/key.txt"), Path.join(dir, "notes/./todo.md"), Path.join(dir, "notes//new.md")]
    clean = [Path.join(dir, "secrets/key.txt"), Path.join(dir, "notes/todo.md"), Path.join(dir, "notes/new.md")]

    assert Filesystem.canonical_paths(backend, paths) == Enum.map(clean, &{:ok, &1})
  end

  defp dir(subject), do: Subject.fixture(subject, :dir, "/")
end
