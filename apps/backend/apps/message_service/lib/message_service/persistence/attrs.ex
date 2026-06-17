defmodule MessageService.Persistence.Attrs do
  @moduledoc false

  def get(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
