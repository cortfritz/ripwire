defmodule Repo.Formatter do
  @moduledoc "Callee module — greeter.ex resolves two remote calls into here."

  def title(text) do
    String.capitalize(text)
  end

  def shout(text) do
    text
    |> title()
    |> String.upcase()
  end
end
