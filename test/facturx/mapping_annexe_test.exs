defmodule Facturx.MappingAnnexeTest do
  @moduledoc """
  Checks annexe B (`docs/reference/mapping-cii-flux1.md`) against the builder.

  The annexe's "Émis" column is maintained by hand, and the count derived
  from it appears in the README, the CHANGELOG and both ADRs. Nothing used to
  keep it honest — the annexe itself records a drift on BT-111. These tests read
  the table and put every path in it to `Facturx.CII.build/2`.

  A failure means the annexe and the code disagree; which of the two is wrong is
  for the reader to decide. If a data item was just implemented, populate it in
  `Facturx.TestInvoice.maximal/0` and tick its row.
  """

  use ExUnit.Case, async: true

  alias Facturx.TestInvoice

  @annexe Path.expand("../../docs/reference/mapping-cii-flux1.md", __DIR__)
  @root "/rsm:CrossIndustryInvoice"

  # Built in EXTENDED, because that is the trajectory the annexe describes: the
  # French extensions are line-level and EN 16931 rejects them. EXTENDED is a
  # structural superset, so the rows already emitted before still resolve here.
  setup_all do
    {:ok, xml} = Facturx.build(%{TestInvoice.maximal() | profile: :extended})
    # Bytes, not codepoints: the document declares UTF-8 and xmerl decodes it
    # itself — handing it codepoints makes `é` fail as an illegal character.
    {doc, _rest} = :xmerl_scan.string(:erlang.binary_to_list(xml), namespace_conformant: false)

    {:ok, xml: xml, doc: doc, rows: rows()}
  end

  test "the maximal invoice is itself valid", %{xml: xml} do
    assert {:ok, :valid} = Facturx.validate_xsd(xml)
  end

  test "and round-trips exactly, which is what makes it a fair witness", %{xml: xml} do
    assert {:ok, parsed} = Facturx.parse(xml)
    assert parsed == %{TestInvoice.maximal() | profile: :extended}
  end

  test "the table has the shape the documentation claims", %{rows: rows} do
    assert length(rows) == 116
    assert Enum.count(rows, & &1.emitted?) == 116
  end

  test "the same invoice still builds and validates in EN 16931", %{} do
    inv = TestInvoice.maximal()

    assert {:ok, xml} = Facturx.build(inv)
    assert {:ok, :valid} = Facturx.validate_xsd(xml)
    # The profile caps line notes at one and strips their subject code, so the
    # round-trip cannot return what went in — that asymmetry is the point.
    assert {:ok, parsed} = Facturx.parse(xml)
    assert [%{notes: [%{content: "Livré en deux lots"}]}] = Enum.take(parsed.lines, 1)
  end

  # Existence is not enough. Nine paths are claimed by two ✅ rows each — BT-110
  # and BT-111 are both `ram:TaxTotalAmount`, told apart only by their
  # currencyID, and the four allowance/charge families differ only by their
  # ChargeIndicator. Asking "does this path resolve?" would let one of each pair
  # disappear unnoticed: dropping :tax_currency really did leave the suite green.
  # Counting the nodes closes that, without having to reproduce the annexe's
  # discriminating predicates in XPath.
  test "each path carries at least as many nodes as it has ✅ rows", %{doc: doc, rows: rows} do
    short =
      rows
      |> Enum.group_by(& &1.path)
      |> Enum.map(fn {path, group} ->
        {path, group, Enum.count(group, & &1.emitted?), length(resolve(doc, path))}
      end)
      |> Enum.filter(fn {_path, _group, expected, found} -> expected > 0 and found < expected end)

    assert short == [],
           "annexe B expects more occurrences than the document carries:\n" <>
             Enum.map_join(short, "\n", fn {path, group, expected, found} ->
               "  #{ids(group)}\texpected #{expected}, found #{found}\t#{path}"
             end)
  end

  test "a path claimed by no emitted row is absent", %{doc: doc, rows: rows} do
    unexpected =
      rows
      |> Enum.group_by(& &1.path)
      |> Enum.reject(fn {_path, group} -> Enum.any?(group, & &1.emitted?) end)
      |> Enum.filter(fn {path, _group} -> resolve(doc, path) != [] end)

    assert unexpected == [],
           "annexe B marks these as not emitted, yet the document carries them:\n" <>
             Enum.map_join(unexpected, "\n", fn {path, group} -> "  #{ids(group)}\t#{path}" end)
  end

  # --- the table ------------------------------------------------------------

  defp rows do
    @annexe
    |> File.read!()
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "| `"))
    |> Enum.map(&parse_row/1)
  end

  defp parse_row(line) do
    [id, _card, _traj, _label, emitted, path | _] =
      line |> String.split("|") |> Enum.drop(1) |> Enum.map(&String.trim/1)

    %{id: unquote_cell(id), emitted?: emitted == "✅", path: path_of(path)}
  end

  # The path cell often carries prose after the path itself — a discriminating
  # value (`… = "VA"`) or a ChargeIndicator. A path never contains a space, so
  # the first one ends it.
  defp path_of(cell) do
    cell
    |> unquote_cell()
    |> String.split(" ", parts: 2)
    |> hd()
    |> String.replace(~r{(?<!/)@}, "/@")
  end

  defp unquote_cell(cell), do: String.trim(cell, "`")

  defp resolve(doc, path) do
    :xmerl_xpath.string(String.to_charlist(@root <> path), doc)
  end

  defp ids(group), do: Enum.map_join(group, ", ", & &1.id)
end
