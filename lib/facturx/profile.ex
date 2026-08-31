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

  # The five profiles are strictly nested: every element name the MINIMUM schema
  # declares is in BASIC WL, and so on up to EXTENDED (verified by diffing the
  # five bundled XSDs). That is what lets a single ordering decide what
  # `Facturx.CII` may emit, instead of one predicate per profile per element.
  #
  # Nesting holds for element *names*, not for where they may appear: BASIC WL
  # allows `ram:ApplicableTradeTax` at header level only, BASIC also at line
  # level. So the floor belongs on the emitter, never on the element.
  @rank %{minimum: 0, basic_wl: 1, basic: 2, en16931: 3, extended: 4}

  @doc "Whether `profile` is `floor` or richer."
  @spec at_least?(Facturx.profile(), Facturx.profile()) :: boolean()
  def at_least?(profile, floor), do: Map.fetch!(@rank, profile) >= Map.fetch!(@rank, floor)

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
