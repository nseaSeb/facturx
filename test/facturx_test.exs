defmodule FacturxTest do
  use ExUnit.Case, async: true

  describe "profiles/0" do
    test "lists the five Factur-X profiles in order" do
      assert Facturx.profiles() == [:minimum, :basic_wl, :basic, :en16931, :extended]
    end
  end

  describe "validate/2" do
    test "cannot pick a schematron when the profile is undetectable (no network call)" do
      assert Facturx.validate("<xml/>") == {:error, {:schematron_not_bundled, nil}}
    end
  end

  test "build/2 emits CII XML for a minimal invoice" do
    assert {:ok, xml} = Facturx.build(%Facturx.Invoice{number: "F-1"})
    assert xml =~ "<ram:ID>F-1</ram:ID>"
  end
end
