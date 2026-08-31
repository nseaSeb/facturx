defmodule Mix.Tasks.Facturx.Harness do
  @shortdoc "Check PDF/A-3 conformance and parity with the Python reference"

  @moduledoc """
  The conformance oracle, as a command rather than a notebook.

      mix facturx.harness

  The test suite proves structure: that what `Facturx.Embed` writes,
  `Facturx.Extract` reads back. It cannot prove conformance, because its
  synthetic base has no font, no OutputIntent and no ICC profile — deliberately,
  so the suite needs no fixtures. Only veraPDF can say whether the output is
  still a valid PDF/A-3, and only the Python `akretion/factur-x` library can say
  whether we still agree with the reference implementation.

  Both need artefacts that are not committed: real invoices under
  `test/fixtures/local/`, and the dev virtualenv. The task says what is missing
  and fails rather than reporting a success it did not establish.

  This file lives under `dev/`, which `elixirc_paths` compiles in `:dev` only, so
  the task never reaches the published package.
  """

  use Mix.Task

  @requirements ["app.start"]

  @root File.cwd!()
  @harness "test/fixtures/local/harness"
  @generator "dev/tools/xref_stream_base.py"

  @impl Mix.Task
  def run(_args) do
    paths = paths()

    case Enum.reject(prerequisites(paths), &File.exists?(elem(&1, 1))) do
      [] ->
        :ok

      missing ->
        Mix.shell().error("Cannot run — missing:")
        for {name, path} <- missing, do: Mix.shell().error("  #{name}: #{path}")
        Mix.raise("the harness proves nothing without its inputs")
    end

    results = checks(paths)
    report(results)

    case Enum.reject(results, & &1.ok) do
      [] -> Mix.shell().info("\nAll #{length(results)} checks passed.")
      bad -> Mix.raise("#{length(bad)} of #{length(results)} checks failed")
    end
  end

  # --- the checks ------------------------------------------------------------

  defp checks(paths) do
    cii = File.read!(paths.cii)

    List.flatten([
      # The tool itself, against a file known to be conformant. A veraPDF that
      # says "compliant" to everything would make every check below meaningless.
      conformance("golden fixture is PDF/A-3b", paths, paths.golden, "3b"),
      conformance("base is PDF/A-2b", paths, paths.base, "2b"),
      python_reference(paths, cii),
      our_output(paths, cii),
      per_profile(paths),
      xref_stream(paths, cii)
    ])
  end

  # The PDF 1.5+ path, on a real file rather than a synthetic one. No tool here
  # writes cross-reference streams — Ghostscript's pdfwrite emits a classic
  # table, pypdf's writer likewise — so the base is re-serialised by
  # dev/tools/xref_stream_base.py, and veraPDF vouches for it before anything is
  # concluded from what we write to it.
  defp xref_stream(paths, cii) do
    base = Path.join(paths.dir, "base_xrefstream.pdf")
    ours = Path.join(paths.dir, "ours_xrefstream.pdf")

    {out, status} =
      System.cmd(paths.python, [@generator, paths.base, base], stderr_to_stdout: true)

    if status != 0 do
      [check("cross-reference stream base builds", false, String.trim(out))]
    else
      {:ok, pdf} = Facturx.generate(File.read!(base), cii)
      File.write!(ours, pdf)

      [
        check("cross-reference stream base builds", true, String.trim(out)),
        check(
          "the base has no trailer keyword",
          not String.contains?(File.read!(base), "\ntrailer"),
          "as a PDF 1.5+ file"
        ),
        conformance("that base is PDF/A-2b", paths, base, "2b"),
        conformance("our output from it is PDF/A-3b", paths, ours, "3b"),
        extraction("our Extract reads it back", ours, cii),
        # An independent parser navigating the cross-reference stream we wrote is
        # what says it is correct, rather than merely self-consistent.
        python_extraction(paths, ours, cii)
      ]
    end
  end

  defp python_extraction(paths, file, expected) do
    out = Path.join(paths.dir, "python_extracted.xml")
    File.rm(out)
    {log, status} = System.cmd(paths.facturx_extract, [file, out], stderr_to_stdout: true)

    cond do
      status != 0 ->
        check("the python reference reads it too", false, summarise(log))

      not File.exists?(out) ->
        check("the python reference reads it too", false, "no output")

      true ->
        check("the python reference reads it too", File.read!(out) == expected, "byte-identical")
    end
  end

  # Regenerate the reference with the Python CLI, then read it with our Extract.
  defp python_reference(paths, cii) do
    File.rm(paths.ref)

    {out, status} =
      System.cmd(paths.facturx_pdfgen, [paths.base, paths.cii, paths.ref], stderr_to_stdout: true)

    [
      # The CLI is chatty, and among other things tries a Saxon server on
      # localhost:5000 that it does not need here. Keep the verdict, drop the log.
      check("python reference regenerates", status == 0, "exit #{status}, #{summarise(out)}"),
      conformance("python reference is PDF/A-3b", paths, paths.ref, "3b"),
      extraction("our Extract reads the python reference", paths.ref, cii)
    ]
  end

  # Our own output: conformant, and carrying exactly what we put in.
  defp our_output(paths, cii) do
    ours = Path.join(paths.dir, "ours.pdf")
    {:ok, pdf} = Facturx.generate(File.read!(paths.base), cii)
    File.write!(ours, pdf)

    [
      conformance("our output is PDF/A-3b", paths, ours, "3b"),
      extraction("our Extract reads our output", ours, cii),
      # The reference and we do not produce the same bytes — different object
      # numbering, different dates — so the comparison that means something is
      # of the payload, which both must carry unchanged.
      check(
        "payloads agree with the reference",
        payload(ours) == payload(paths.ref),
        "ours #{byte_size(payload(ours))} B vs reference #{byte_size(payload(paths.ref))} B"
      )
    ]
  end

  # Every profile, since build/2 now emits a different document for each — and
  # the XMP carries the profile as its ConformanceLevel, so each one is a
  # different PDF/A-3 file to validate.
  #
  # The invoice is the harness fixture read back through `parse/1` rather than a
  # struct written here: it exercises the real path, and a document produced
  # elsewhere is the interesting input.
  defp per_profile(paths) do
    base = File.read!(paths.base)
    {:ok, invoice} = Facturx.parse(File.read!(paths.cii))

    for profile <- Facturx.profiles() do
      case Facturx.build(invoice, profile: profile) do
        {:ok, xml} ->
          {:ok, pdf} = Facturx.generate(base, xml, profile: profile)
          path = Path.join(paths.dir, "profile_#{profile}.pdf")
          File.write!(path, pdf)

          conformance("#{profile} output is PDF/A-3b", paths, path, "3b")

        {:error, reason} ->
          check("#{profile} document builds", false, inspect(reason))
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp conformance(label, paths, file, flavour) do
    {out, _} = System.cmd(paths.verapdf, ["-f", flavour, file], stderr_to_stdout: true)
    failed = capture(out, ~r/failedRules="(\d+)"/)

    check(label, out =~ ~s(isCompliant="true"), "failedRules=#{failed || "?"}")
  end

  defp extraction(label, file, expected) do
    case Facturx.extract(File.read!(file)) do
      {:ok, %{xml: ^expected}} -> check(label, true, "byte-identical")
      {:ok, %{xml: other}} -> check(label, false, "differs (#{byte_size(other)} B)")
      {:error, reason} -> check(label, false, inspect(reason))
    end
  end

  defp payload(file) do
    {:ok, %{xml: xml}} = Facturx.extract(File.read!(file))
    xml
  end

  defp capture(out, re), do: (Regex.run(re, out) || [nil, nil]) |> List.last()

  # The last line that says something happened, or the last line at all.
  defp summarise(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.contains?(&1, "generated"))
    |> List.last()
    |> case do
      nil -> out |> String.split("\n", trim: true) |> List.last() |> to_string()
      line -> line |> String.split("] ") |> List.last()
    end
  end

  defp check(label, ok?, detail), do: %{label: label, ok: ok?, detail: detail}

  defp report(results) do
    width = results |> Enum.map(&String.length(&1.label)) |> Enum.max()

    for %{label: label, ok: ok?, detail: detail} <- results do
      Mix.shell().info(
        "#{if ok?, do: "ok  ", else: "FAIL"}  #{String.pad_trailing(label, width)}  #{detail}"
      )
    end
  end

  defp paths do
    dir = Path.join(@root, @harness)

    %{
      dir: dir,
      verapdf: System.find_executable("verapdf") || "/opt/homebrew/bin/verapdf",
      python: Path.join(@root, ".venv-dev/bin/python"),
      facturx_pdfgen: Path.join(@root, ".venv-dev/bin/facturx-pdfgen"),
      facturx_extract: Path.join(@root, ".venv-dev/bin/facturx-pdfextractxml"),
      golden: Path.join(@root, "test/fixtures/local/facturx-en16931.pdf"),
      base: Path.join(dir, "base.pdf"),
      cii: Path.join(dir, "cii.xml"),
      ref: Path.join(dir, "ref.pdf")
    }
  end

  defp prerequisites(paths) do
    [
      {"veraPDF", paths.verapdf},
      {"python", paths.python},
      {"python facturx-pdfgen", paths.facturx_pdfgen},
      {"python facturx-pdfextractxml", paths.facturx_extract},
      {"the cross-reference stream generator", Path.join(@root, @generator)},
      {"golden fixture", paths.golden},
      {"harness base", paths.base},
      {"harness cii.xml", paths.cii}
    ]
  end
end
