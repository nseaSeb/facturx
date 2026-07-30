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

  # BT-23 "cadre de facturation", rule G1.02 of the French external
  # specifications v3.2. See docs/reference/reforme-fr.md.
  @business_processes ~w(B1 S1 M1 B2 S2 M2 B4 S4 M4 S5 S6 B7 S7)

  @doc """
  The invoicing framework codes (BT-23) accepted by the French mandate.

      B1/S1/M1  goods / services / mixed
      B2/S2/M2  same, already paid
      B4/S4/M4  same, final invoice after a down payment
      S5        services, filed by a subcontractor
      S6        services, filed by a co-contractor
      B7/S7     goods / services already e-reported (VAT already collected)
  """
  @spec business_processes() :: [String.t()]
  def business_processes, do: @business_processes

  # BT-8 code list, restricted by EN 16931 itself (rule BR-CL-06) to a subset of
  # UNTDID 2475. The enumeration is the one bundled in
  # priv/schematron/en16931/FACTUR-X_EN16931_codedb.xml (code list id=28).
  # Note: CII uses UNTDID 2475 here; UBL uses UNTDID 2005 (3/35/432) instead.
  @vat_point_date_codes ~w(5 29 72)

  @doc """
  The VAT point date codes (BT-8) allowed by EN 16931 in CII syntax.

      "5"   date of invoice   — VAT due on invoicing ("TVA sur les débits")
      "29"  delivery date     — VAT due on delivery (goods)
      "72"  date of payment   — VAT due on collection ("à l'encaissement")

  Unlike BT-23, this list is imposed by the standard (not by France), so it is
  always enforced.
  """
  @spec vat_point_date_codes() :: [String.t()]
  def vat_point_date_codes, do: @vat_point_date_codes

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
