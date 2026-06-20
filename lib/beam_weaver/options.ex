defmodule BeamWeaver.Options do
  @moduledoc false

  def atom_enum!(name, value, allowed) when is_atom(value) do
    if value in allowed do
      value
    else
      raise ArgumentError, invalid_atom_message(name, value, allowed)
    end
  end

  def atom_enum!(name, value, allowed) when is_binary(value) do
    raise ArgumentError, binary_atom_message(name, value, allowed)
  end

  def atom_enum!(name, value, allowed) do
    raise ArgumentError, invalid_atom_message(name, value, allowed)
  end

  def atom_enum_error(name, value, allowed) when is_atom(value) do
    if value in allowed do
      :ok
    else
      {:error, invalid_atom_message(name, value, allowed)}
    end
  end

  def atom_enum_error(name, value, allowed) when is_binary(value) do
    {:error, binary_atom_message(name, value, allowed)}
  end

  def atom_enum_error(name, value, allowed),
    do: {:error, invalid_atom_message(name, value, allowed)}

  defp binary_atom_message(name, value, allowed) do
    suggestion =
      if known_string?(value, allowed) do
        "; use :#{value}"
      else
        ""
      end

    "#{name} must be an atom, got #{inspect(value)}#{suggestion}"
  end

  defp invalid_atom_message(name, value, allowed) do
    "#{name} must be one of #{format_allowed(allowed)}, got #{inspect(value)}"
  end

  defp known_string?(value, allowed), do: value in Enum.map(allowed, &Atom.to_string/1)

  defp format_allowed(allowed) do
    allowed
    |> Enum.map_join(", ", &inspect/1)
  end
end
