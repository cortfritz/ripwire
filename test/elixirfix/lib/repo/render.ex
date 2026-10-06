defprotocol Repo.Render do
  @doc "A protocol — t=\"iface\", and its impl below deliberately mints no container symbol."
  def render(term)
end

defimpl Repo.Render, for: Repo.Greeter do
  def render(%Repo.Greeter{name: name}) do
    Repo.Formatter.title(name)
  end
end
