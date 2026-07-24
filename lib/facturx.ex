defmodule Facturx do
  @moduledoc """
  Factur-X / ZUGFeRD hybrid e-invoices in pure Elixir.

  A Factur-X invoice is a PDF/A-3 document with a machine-readable CII XML
  (EN 16931) embedded inside it. This module is the public facade; the work is
  split across:

    * `Facturx.CII` — build/parse the CII XML (pure Elixir)
    * `Facturx.Extract` — pull the embedded XML out of a PDF (pure Elixir)
    * `Facturx.Embed` — inject XML into an existing PDF/A-3 (pure Elixir)
    * `Facturx.Validate` — optional Schematron validation over a Saxon endpoint

  See `docs/adr/0001-perimetre-et-architecture.md` for scope decisions.
  """

  alias Facturx.{CII, Embed, Extract, Invoice, Validate}

  @typedoc "Factur-X / ZUGFeRD conformance profiles, from leanest to richest."
  @type profile :: :minimum | :basic_wl | :basic | :en16931 | :extended

  @profiles [:minimum, :basic_wl, :basic, :en16931, :extended]

  @doc "The supported Factur-X profiles."
  @spec profiles() :: [profile()]
  def profiles, do: @profiles

  @doc """
  Build a Factur-X PDF: embed the CII XML for `invoice` into a **PDF/A-3**.

  `pdf_a3` must already be a valid PDF/A-3 (the visual invoice). Pass either an
  `Facturx.Invoice` struct or a ready CII XML binary as the payload.
  """
  @spec generate(binary(), Invoice.t() | binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def generate(pdf_a3, invoice_or_xml, opts \\ [])

  def generate(pdf_a3, %Invoice{} = invoice, opts) when is_binary(pdf_a3) do
    with {:ok, xml} <- CII.build(invoice, opts) do
      Embed.embed(pdf_a3, xml, opts)
    end
  end

  def generate(pdf_a3, xml, opts) when is_binary(pdf_a3) and is_binary(xml) do
    Embed.embed(pdf_a3, xml, opts)
  end

  @doc "Extract the embedded CII XML (and metadata) from a Factur-X PDF."
  @spec extract(binary()) ::
          {:ok, %{xml: binary(), profile: profile() | nil, filename: String.t()}}
          | {:error, term()}
  defdelegate extract(pdf), to: Extract

  @doc "Parse a CII XML binary into an `Facturx.Invoice` struct."
  @spec parse(binary()) :: {:ok, Invoice.t()} | {:error, term()}
  defdelegate parse(xml), to: CII

  @doc "Build a CII XML binary from an `Facturx.Invoice` struct."
  @spec build(Invoice.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  defdelegate build(invoice, opts \\ []), to: CII

  @doc """
  Validate CII XML against the EN 16931 Schematron (business rules).

  Optional: requires a reachable Saxon endpoint (`:endpoint` opt) and the `req`
  dependency. See `Facturx.Validate`.
  """
  @spec validate(binary(), keyword()) ::
          {:ok, :valid} | {:error, {:invalid, [map()]}} | {:error, term()}
  defdelegate validate(xml, opts \\ []), to: Validate

  @doc """
  Validate CII XML against the EN 16931 **XSD** (structure/types).

  Pure Elixir, in-process (OTP `:xmerl_xsd`) — no external tool. See `Facturx.XSD`.
  """
  @spec validate_xsd(binary(), keyword()) ::
          {:ok, :valid} | {:error, {:invalid, [String.t()]}} | {:error, term()}
  defdelegate validate_xsd(xml, opts \\ []), to: Facturx.XSD, as: :validate
end
