defmodule Facturx.Profile do
  @moduledoc false
  # Single source of truth for mapping between Factur-X profiles and the CII
  # guideline URN, shared by CII / Extract / Validate.

  @spec to_urn(Facturx.profile()) :: String.t()
  def to_urn(:minimum), do: "urn:factur-x.eu:1p0:minimum"
  def to_urn(:basic_wl), do: "urn:factur-x.eu:1p0:basicwl"
  def to_urn(:basic), do: "urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic"
  def to_urn(:en16931), do: "urn:cen.eu:en16931:2017"
  def to_urn(:extended), do: "urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended"

  @spec from_urn(String.t() | nil) :: Facturx.profile() | nil
  def from_urn(nil), do: nil

  def from_urn(urn) do
    cond do
      urn =~ "minimum" -> :minimum
      urn =~ "basicwl" -> :basic_wl
      urn =~ "basic" -> :basic
      urn =~ "extended" -> :extended
      urn =~ "en16931" -> :en16931
      true -> nil
    end
  end

  @doc "Detect the profile from a CII XML binary via its guideline URN."
  @spec detect(binary()) :: Facturx.profile() | nil
  def detect(xml) do
    case Regex.run(
           ~r/GuidelineSpecifiedDocumentContextParameter>\s*<[a-zA-Z]+:ID>([^<]+)/,
           xml
         ) do
      [_, id] -> from_urn(id)
      _ -> nil
    end
  end
end
