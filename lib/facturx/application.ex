defmodule Facturx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [Facturx.XSD.Cache]
    Supervisor.start_link(children, strategy: :one_for_one, name: Facturx.Supervisor)
  end
end
