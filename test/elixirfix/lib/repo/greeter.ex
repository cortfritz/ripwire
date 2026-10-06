defmodule Repo.Greeter do
  @moduledoc "The fixture's main module — one of every capture shape the query names."

  alias Repo.Formatter
  import Repo.Util
  require Logger

  defstruct [:name, :salutation]

  @default_greeting "hello"

  defguard is_name(n) when is_binary(n) and n != ""

  @doc "A def with a guard clause — the binary_operator head shape."
  def greet(name) when is_name(name) do
    name
    |> trim()
    |> Formatter.title()
    |> emit()
  end

  # The keyword-list body form: a real def, and deliberately body-less by the do_block measure.
  def greet(_other), do: @default_greeting

  # A zero-arity head written without parentheses — the bare-identifier shape.
  def default do
    @default_greeting
  end

  defp emit(text) do
    Logger.debug(text)
    Formatter.shout(text)
  end

  # A struct FIELD READ, not a call. `record.title` is `(call target: (dot left: (identifier) ...))` —
  # the SAME node shape as the remote call `Formatter.title(...)` in greet/1 above, separated only by
  # what sits on the LEFT of the dot: an `alias` names a module, a plain `identifier` names a variable.
  # `title` is a real def in formatter.ex, so if the query does not discriminate on the left, this field
  # read mints a phantom `label -> title` call edge. Arm 5b pins that it does not.
  def label(record) do
    record.title
  end

  defmacro trace(expr) do
    quote do
      Logger.debug(unquote(expr))
    end
  end
end
