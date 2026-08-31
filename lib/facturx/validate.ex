defmodule Facturx.Validate do
  @moduledoc """
  **Optional** Schematron validation against the EN 16931 business rules.

  The EN 16931 Schematron compiles to XSLT 2.0, which the BEAM cannot run. Like
  the Python `akretion/factur-x` library, we delegate to a Saxon server over
  HTTP (`req` — declared `optional` so non-validating callers don't pull an HTTP
  client). The compiled schematron XSLT ships in `priv/schematron/`.

  Run a Saxon server (e.g. `ghcr.io/willemvlh/saxon-server`, port 5000) and
  point `:endpoint` at its `/transform` route. The transform is sent the XML and
  the XSLT as a `multipart/form-data` body and returns an SVRL report, which we
  interpret into `failed-assert` / `successful-report` findings.

  Findings are split by SVRL severity: only those flagged `"warning"` or `"info"`
  are non-blocking, so a document carrying nothing worse stays **valid**.

      {:ok, :valid}
      {:ok, {:valid_with_warnings, [%{flag: "warning", message: "…"}]}}
      {:error, {:invalid, [%{flag: nil, message: "…"}]}}

  Only three assertions in the bundled schematron are flagged `warning`, and two
  are business rules rather than cosmetics: `PEPPOL-EN16931-R008` (no empty
  elements), `BR-29` (BT-74 must be ≥ BT-73) and `BR-FX-EN-04` (delivery or period
  information, and only on DE-to-DE invoices). So `{:ok, {:valid_with_warnings, _}}`
  is not necessarily benign — inspect the findings.

  The common trigger is R008: with neither `:ship_to` nor `:delivery_date` set,
  `Facturx.CII` still has to emit an empty `ram:ApplicableHeaderTradeDelivery`,
  which CII requires. Supply delivery data and a plain `{:ok, :valid}` is the
  normal outcome.

  > Privacy: a **public** Saxon endpoint means sending real invoice data to a
  > third party. Self-host the Saxon server in production.

      {:ok, :valid} = Facturx.validate(xml, profile: :en16931,
                                       endpoint: "http://localhost:5000/transform")

  All five profile schematrons ship, under `priv/schematron/`. They are the bulk
  of the package — 4.4 MB on disk — but they compress to about 78 KB of the
  published tarball, which is why all five are bundled rather than the two that
  once were. An unknown profile returns
  `{:error, {:schematron_not_bundled, profile}}`.
  """

  @default_endpoint "http://localhost:5000/transform"

  # profile => {bundled xsl (relative to priv/schematron), codedb filename,
  #             public codedb URL used to resolve document(...) in the XSLT}
  @schematron %{
    minimum:
      {"minimum/Factur-X_1.09_MINIMUM.xsl", "FACTUR-X_MINIMUM_codedb.xml",
       "https://raw.githubusercontent.com/akretion/factur-x/refs/heads/master/src/facturx/xsd_and_schematron/facturx-minimum/FACTUR-X_MINIMUM_codedb.xml"},
    basic_wl:
      {"basicwl/Factur-X_1.09_BASICWL.xsl", "FACTUR-X_BASIC-WL_codedb.xml",
       "https://raw.githubusercontent.com/akretion/factur-x/refs/heads/master/src/facturx/xsd_and_schematron/facturx-basicwl/FACTUR-X_BASIC-WL_codedb.xml"},
    basic:
      {"basic/Factur-X_1.09_BASIC.xsl", "FACTUR-X_BASIC_codedb.xml",
       "https://raw.githubusercontent.com/akretion/factur-x/refs/heads/master/src/facturx/xsd_and_schematron/facturx-basic/FACTUR-X_BASIC_codedb.xml"},
    en16931:
      {"en16931/Factur-X_1.09_EN16931.xsl", "FACTUR-X_EN16931_codedb.xml",
       "https://raw.githubusercontent.com/akretion/factur-x/refs/heads/master/src/facturx/xsd_and_schematron/facturx-en16931/FACTUR-X_EN16931_codedb.xml"},
    extended:
      {"extended/Factur-X_1.09_EXTENDED.xsl", "FACTUR-X_EXTENDED_codedb.xml",
       "https://raw.githubusercontent.com/akretion/factur-x/refs/heads/master/src/facturx/xsd_and_schematron/facturx-extended/FACTUR-X_EXTENDED_codedb.xml"}
  }

  @typedoc """
  A schematron finding.

  `:flag` is the SVRL severity when the rule declares one. Only findings flagged
  `"warning"` or `"info"` are treated as non-blocking; everything else — including
  an absent flag — counts as an error.
  """
  @type violation :: %{
          message: String.t() | nil,
          location: String.t() | nil,
          test: String.t() | nil,
          flag: String.t() | nil
        }

  # SVRL flags that do not make a document invalid. Anything else, `nil`
  # included, is an error: defaulting to "invalid" is the safe way round.
  @warning_flags ~w(warning info)

  @doc """
  Validate `xml` against the EN 16931 Schematron via a Saxon endpoint.

  Options:

    * `:endpoint` — Saxon `/transform` URL (defaults to the app env
      `config :facturx, Facturx.Validate, endpoint: ...`, then
      `#{inspect(@default_endpoint)}`)
    * `:profile` — schematron level (defaults to the profile detected in the XML)
    * `:codedb_url` — override the code-list DB URL the XSLT resolves
    * `:receive_timeout` — HTTP receive timeout (ms), default 20_000
  """
  @spec validate(binary(), keyword()) ::
          {:ok, :valid}
          | {:ok, {:valid_with_warnings, [violation()]}}
          | {:error, {:invalid, [violation()]}}
          | {:error, term()}
  def validate(xml, opts \\ []) when is_binary(xml) do
    with {:ok, xsl} <- schematron_xsl(xml, opts),
         :ok <- ensure_req() do
      post(endpoint(opts), strip_bom(xml), xsl, opts)
    end
  end

  # A caller may supply a compiled schematron XSLT directly (`:xsl`) — useful for
  # custom rule sets (e.g. fr-ctc) or profiles we don't bundle.
  defp schematron_xsl(xml, opts) do
    case opts[:xsl] do
      xsl when is_binary(xsl) ->
        {:ok, xsl}

      _ ->
        with {:ok, profile} <- resolve_profile(xml, opts), do: load_xsl(profile, opts)
    end
  end

  # --- schematron selection -------------------------------------------------

  defp resolve_profile(xml, opts) do
    profile = opts[:profile] || detect_profile(xml)

    if Map.has_key?(@schematron, profile) do
      {:ok, profile}
    else
      {:error, {:schematron_not_bundled, profile}}
    end
  end

  defp detect_profile(xml), do: Facturx.Profile.detect(xml)

  defp load_xsl(profile, opts) do
    {file, codedb_file, default_codedb_url} = Map.fetch!(@schematron, profile)
    path = Application.app_dir(:facturx, ["priv", "schematron", file])

    case File.read(path) do
      {:ok, xsl} ->
        codedb_url = opts[:codedb_url] || default_codedb_url
        # The XSLT resolves the code-list DB via document('<filename>'); point it
        # at a URL the Saxon server can fetch (matches the Python library).
        {:ok, String.replace(xsl, codedb_file, codedb_url)}

      {:error, reason} ->
        {:error, {:schematron_unreadable, path, reason}}
    end
  end

  # --- HTTP to the Saxon server --------------------------------------------

  defp post(url, xml, xsl, opts) do
    fields = [
      xml: {xml, filename: "file_to_check.xml", content_type: "text/xml"},
      xsl: {xsl, filename: "schematron.xsl", content_type: "text/xml"}
    ]

    req_opts = [
      form_multipart: fields,
      receive_timeout: Keyword.get(opts, :receive_timeout, 20_000),
      decode_body: false
    ]

    # Indirect dispatch: `:req` is an optional dependency, so referencing it via
    # apply/3 avoids a compile-time warning in projects that don't pull it in.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(Req, :post, [url, req_opts]) do
      {:ok, %{status: 200, body: svrl}} -> interpret(svrl)
      {:ok, %{status: status}} -> {:error, {:saxon_http_error, status}}
      {:error, reason} -> {:error, {:saxon_unreachable, reason}}
    end
  end

  # --- SVRL interpretation --------------------------------------------------

  @doc false
  def interpret(svrl) when is_binary(svrl) do
    case Saxy.SimpleForm.parse_string(svrl) do
      {:ok, root} ->
        root
        |> collect([])
        |> Enum.reverse()
        |> Enum.split_with(&(&1.flag in @warning_flags))
        |> classify()

      {:error, reason} ->
        {:error, {:invalid_svrl, reason}}
    end
  end

  # Warnings must not make a document invalid: the EN 16931 schematron reports
  # PEPPOL-EN16931-R008 ("no empty elements") as flag="warning", and CII forces
  # an empty ram:ApplicableHeaderTradeDelivery when there is no delivery data —
  # so a conformant invoice always carries that one.
  defp classify({_warnings, [_ | _] = errors}), do: {:error, {:invalid, errors}}
  defp classify({[], []}), do: {:ok, :valid}
  defp classify({warnings, []}), do: {:ok, {:valid_with_warnings, warnings}}

  defp collect({name, attrs, content}, acc) do
    acc =
      if local(name) in ["failed-assert", "successful-report"] do
        [violation(attrs, content) | acc]
      else
        acc
      end

    Enum.reduce(content, acc, fn
      {_, _, _} = child, a -> collect(child, a)
      _text, a -> a
    end)
  end

  defp violation(attrs, content) do
    %{
      message: child_text(content, "text"),
      location: attr(attrs, "location"),
      test: attr(attrs, "test"),
      flag: attr(attrs, "flag")
    }
  end

  defp child_text(content, local_name) do
    Enum.find_value(content, fn
      {n, _, c} -> if local(n) == local_name, do: text_of(c)
      _ -> nil
    end)
  end

  defp text_of(content) do
    case content |> Enum.filter(&is_binary/1) |> Enum.join() |> String.trim() do
      "" -> nil
      v -> v
    end
  end

  defp local(name), do: name |> String.split(":") |> List.last()

  defp attr(attrs, key) do
    case List.keyfind(attrs, key, 0) do
      {_, v} -> v
      _ -> nil
    end
  end

  # --- helpers --------------------------------------------------------------

  defp endpoint(opts) do
    opts[:endpoint] ||
      Application.get_env(:facturx, __MODULE__, [])[:endpoint] ||
      @default_endpoint
  end

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(xml), do: xml

  defp ensure_req do
    if Code.ensure_loaded?(Req) do
      :ok
    else
      {:error, {:req_missing, ~s(add {:req, "~> 0.5"} to your deps to use Facturx.Validate)}}
    end
  end
end
