defmodule Facturx.XSD.Cache do
  @moduledoc """
  Long-lived owner of the compiled XSD schemas.

  Started by the `:facturx` application supervisor; there is nothing to call.
  It is documented because `Facturx.XSD` describes the two speeds its presence
  explains.

  `:xmerl_xsd` stores a compiled schema in an ETS table tied to the process that
  compiled it. This GenServer compiles each bundled schema once (so it owns
  those tables and keeps them alive) and publishes the compiled state via
  `:persistent_term`. Any process can then read that state and validate in
  parallel (~0.6 ms/call) against the shared, read-only (`:protected`) table,
  instead of recompiling (~5 ms) on every call.

  A schema that fails to compile is not cached and is not fatal: validation
  falls back to per-call compilation, and the reason is logged at `:warning` so
  the slow path is never a silent mystery.
  """
  use GenServer
  require Logger

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    for {profile, path} <- Facturx.XSD.bundled() do
      case :xmerl_xsd.process_schema(path) do
        {:ok, state} ->
          :persistent_term.put(Facturx.XSD.pt_key(profile), state)

        # A schema that fails to compile is simply not cached; validation falls
        # back to per-call compilation. Never crash app boot over it — but make
        # the reason visible so the slow path isn't a silent mystery.
        {:error, reason} ->
          Logger.warning(
            "Facturx.XSD: could not precompile #{inspect(profile)} schema " <>
              "(validation will fall back to per-call compilation): " <>
              inspect(reason, limit: 5)
          )
      end
    end

    {:ok, %{}}
  end
end
